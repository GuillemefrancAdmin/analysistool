# Measures how much of the completed corpus's final architecture_spec_writer
# output is schema-valid and placeholder-free, without another slow manual
# sampling pass. See fix-architecture-spec-synthesis: a 91.0%/97.3%
# placeholder rate on functional_requirements/technical_debt_and_code_smells
# was found by hand-sampling and grepping, once. This script makes that a
# fast, one-command, re-runnable, whole-corpus check instead -- for
# confirming that fix worked, and for any future change to the same stage.
#
# Read-only: makes no pipeline-state decisions, blocks nothing, writes
# nothing.
#
# Usage:
#   .\verify_synthesis_quality.ps1
#   .\verify_synthesis_quality.ps1 -OutputsRoot ".analysis-state\outputs" -SchemaPath "templates\source-code-analysis-schema.json"

param(
    [string]$OutputsRoot = "",
    [string]$SchemaPath = ""
)

# Relaunch under PowerShell 7 -- Test-Json doesn't exist in Windows
# PowerShell 5.1 at all (added in PS 6.1), so this script can't run there
# regardless of manifest/output size. See the matching, more fully-commented
# block in run_analysis_pipeline_parallel.ps1.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) {
        $pwshExe = @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe"
            "$env:LOCALAPPDATA\Programs\PowerShell-7.6.6\pwsh.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if ($pwshExe) {
        $paramsForward = @{}
        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [switch]) { $paramsForward[$key] = [bool]$val.IsPresent }
            else { $paramsForward[$key] = $val }
        }
        $bootstrapPath = [System.IO.Path]::GetTempFileName()
        $exitCode = 1
        try {
            ($paramsForward | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $bootstrapPath -Encoding UTF8
            $cmd = "`$h = Get-Content -LiteralPath '$bootstrapPath' -Raw | ConvertFrom-Json -AsHashtable; & '$PSCommandPath' @h"
            & $pwshExe -NoProfile -Command $cmd
            $exitCode = $LASTEXITCODE
        }
        finally {
            Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction SilentlyContinue
        }
        exit $exitCode
    }
    throw "pwsh.exe (PowerShell 7) not found -- Test-Json requires PS 6.1+, this script cannot run under Windows PowerShell 5.1."
}

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutputsRoot) { $OutputsRoot = Join-Path $Root ".analysis-state\outputs" }
if (-not $SchemaPath) { $SchemaPath = Join-Path $Root "templates\source-code-analysis-schema.json" }

if (-not (Test-Path -LiteralPath $OutputsRoot)) {
    throw "No outputs directory found at $OutputsRoot."
}
if (-not (Test-Path -LiteralPath $SchemaPath)) {
    throw "No schema file found at $SchemaPath."
}

# The schema's own top-level `required` list, read once so this stays in
# sync automatically rather than hardcoding it. Used to separately track
# "missing entire required section" (a pre-existing gap between the prompt
# and the schema, predating and broader than fix-architecture-spec-
# synthesis -- the prompt has never asked for source_evidence,
# execution_context, interface_contracts, or token_usage at all) from
# actual content-quality problems within the sections the prompt DOES ask
# for. Without this split, Test-Json's whole-document pass/fail is
# dominated by that unrelated gap and would make this fix look like it
# didn't work even when the two fields it targets are fully repaired.
$schemaObj = Get-Content -LiteralPath $SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
$RequiredTopLevelKeys = @($schemaObj.required)

# Old-format (pre-fix-architecture-spec-synthesis) placeholder markers: the
# prompt's own literal template text prior to that change, echoed verbatim
# as if it were real content.
$OldPlaceholderPatterns = @{
    functional_requirements        = '^REQ-ID \|'
    technical_debt_and_code_smells = '^ISSUE-ID \|'
}
# New-format placeholder marker: the fixed prompt's angle-bracketed
# format-template tokens, if a model still echoes them instead of real
# values derived from its findings.
$NewPlaceholderPattern = '^<.*>$'

# Classifies one field's array value into exactly one bucket:
#   empty           - genuinely empty array (legitimate or not, ambiguous)
#   old_placeholder - flat strings matching the pre-fix literal template text
#   wrong_shape     - flat strings, but not the exact placeholder text (real
#                     content synthesized in the old, schema-mismatched shape)
#   new_placeholder - structured objects whose values are still the fixed
#                     prompt's own bracketed template tokens
#   real            - structured objects with real, non-template content
function Get-FieldQualityBucket {
    param($Items, [string]$OldPattern)
    if (-not $Items -or $Items.Count -eq 0) { return "empty" }

    $anyString = $false
    $allOldPlaceholder = $true
    $allNewPlaceholder = $true
    foreach ($item in $Items) {
        if ($item -is [string]) {
            $anyString = $true
            if ($item -notmatch $OldPattern) { $allOldPlaceholder = $false }
            $allNewPlaceholder = $false
        }
        else {
            $allOldPlaceholder = $false
            $propValues = @($item.PSObject.Properties | ForEach-Object { [string]$_.Value })
            $hasBracketedValue = @($propValues | Where-Object { $_ -match $NewPlaceholderPattern }).Count -gt 0
            if (-not $hasBracketedValue) { $allNewPlaceholder = $false }
        }
    }

    if ($anyString) {
        if ($allOldPlaceholder) { return "old_placeholder" }
        return "wrong_shape"
    }
    if ($allNewPlaceholder) { return "new_placeholder" }
    return "real"
}

$files = Get-ChildItem -LiteralPath $OutputsRoot -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue
$total = 0
$schemaValid = 0
$parseErrors = 0
$missingOnlyTopLevelSections = 0
$missingSectionCounts = @{}
foreach ($key in $RequiredTopLevelKeys) { $missingSectionCounts[$key] = 0 }
$fieldStats = @{}
foreach ($field in $OldPlaceholderPatterns.Keys) {
    $fieldStats[$field] = @{ empty = 0; old_placeholder = 0; wrong_shape = 0; new_placeholder = 0; real = 0 }
}

foreach ($file in $files) {
    $total++

    $raw = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8; break }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }

    $isSchemaValid = [bool](Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)
    if ($isSchemaValid) { $schemaValid++ }

    try { $parsed = $raw | ConvertFrom-Json }
    catch { $parseErrors++; continue }

    $presentKeys = @($parsed.PSObject.Properties.Name)
    $missingKeys = @($RequiredTopLevelKeys | Where-Object { $_ -notin $presentKeys })
    foreach ($key in $missingKeys) { $missingSectionCounts[$key]++ }
    # A file invalid solely because of the pre-existing missing-section gap
    # (not anything this fix targets) would otherwise be silently absorbed
    # into the generic "not schema-valid" count above. Treating "missing
    # >=1 required top-level section" as the flag directly is precise
    # enough for this report's purpose -- distinguishing the two known gap
    # categories -- without a second, more expensive Test-Json pass per file.
    if (-not $isSchemaValid -and $missingKeys.Count -gt 0) {
        $missingOnlyTopLevelSections++
    }

    foreach ($field in $fieldStats.Keys) {
        $bucket = Get-FieldQualityBucket -Items $parsed.$field -OldPattern $OldPlaceholderPatterns[$field]
        $fieldStats[$field][$bucket]++
    }
}

Write-Host ("--- Synthesis quality report ({0}) ---" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
Write-Host ("Files checked     : {0}" -f $total)
Write-Host ("Parse errors      : {0}" -f $parseErrors)
if ($total -gt 0) {
    Write-Host ("Schema-valid (whole document): {0} ({1:P1})" -f $schemaValid, ($schemaValid / $total))
    Write-Host ("  of which invalid due to >=1 missing required top-level section: {0} ({1:P1})" -f $missingOnlyTopLevelSections, ($missingOnlyTopLevelSections / $total))
}
Write-Host ""
Write-Host "Missing required top-level sections (pre-existing gap -- the prompt" -ForegroundColor DarkYellow
Write-Host "never asks for these; NOT targeted by fix-architecture-spec-synthesis):" -ForegroundColor DarkYellow
foreach ($key in $RequiredTopLevelKeys) {
    if ($missingSectionCounts[$key] -gt 0) {
        $pct = if ($total -gt 0) { $missingSectionCounts[$key] / $total } else { 0 }
        Write-Host ("  {0,-24}: {1,5} ({2:P1})" -f $key, $missingSectionCounts[$key], $pct) -ForegroundColor DarkYellow
    }
}
Write-Host ""
Write-Host "Field-level content quality (what this fix targets):" -ForegroundColor Cyan
foreach ($field in $fieldStats.Keys) {
    Write-Host ("Field: {0}" -f $field) -ForegroundColor Yellow
    $s = $fieldStats[$field]
    foreach ($key in @("real", "empty", "old_placeholder", "wrong_shape", "new_placeholder")) {
        $pct = if ($total -gt 0) { $s[$key] / $total } else { 0 }
        Write-Host ("  {0,-16}: {1,5} ({2:P1})" -f $key, $s[$key], $pct)
    }
}
