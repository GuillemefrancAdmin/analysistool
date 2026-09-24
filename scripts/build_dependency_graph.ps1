# Builds a repo-wide file-to-file dependency graph and file-to-table usage
# map from already-completed per-file analysis output, for migration
# scoping/sequencing. Every one of the ten per-file pipeline stages, the
# queue/state model, and every existing report operate on one file at a
# time -- nothing anywhere stitches per-file outputs into a system-level
# picture. This is purely a resolution/aggregation pass over already-
# extracted data: no new LLM calls, no pipeline changes.
#
# File-to-file: internal_module_dependencies is free text the model wrote
# (e.g. "gerepile", "global_procedure_division.cbl"), unlinked to any real
# file path. Resolved here in three tiers, most specific first, each
# case-insensitive: exact relative path, basename with extension, basename
# without extension (COBOL/4GL cross-references commonly omit the
# extension). A tier that matches more than one file stops at "ambiguous"
# rather than falling through to a looser tier that might coincidentally
# disambiguate -- a looser tier is by construction less reliable, not a
# legitimate tiebreaker. Every entry ends up resolved (exactly one match),
# ambiguous (more than one candidate), or unresolved (no candidate) --
# never silently dropped, never silently guessed.
#
# File-to-table: database_interactions is already structured
# (operation_type/target_entity/execution_mechanism) -- a pure aggregation
# by target_entity, not a resolution problem.
#
# Read-only against .analysis-state/outputs/ only. Never touches
# manifest.json or any per-file state file, takes no cross-process lock --
# safe to run anytime, including while pipeline workers are active.
#
# No PowerShell-7 relaunch guard: unlike queue_eta.ps1/backfill_new_
# stage.ps1/verify_synthesis_quality.ps1 (each needing PS7 for a specific
# reason -- manifest.json's size, or Test-Json not existing before PS 6.1),
# this only parses individual per-file report JSONs, each tens of KB --
# well within what Windows PowerShell 5.1 handles natively.
#
# When to use: after files have completed the analysis chain, whenever a
# system-level view is needed (migration scoping/sequencing across files).
#
# Usage:
#   .\build_dependency_graph.ps1
#   .\build_dependency_graph.ps1 -OutputsRoot ".analysis-state\outputs" -GraphOutDir ".analysis-state\dependency-graph"

param(
    [string]$OutputsRoot = "",
    [string]$GraphOutDir = "",
    [int]$TopN = 15
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutputsRoot) { $OutputsRoot = Join-Path $Root ".analysis-state\outputs" }
if (-not $GraphOutDir) { $GraphOutDir = Join-Path $Root ".analysis-state\dependency-graph" }

if (-not (Test-Path -LiteralPath $OutputsRoot)) {
    throw "No outputs directory found at $OutputsRoot."
}

function Read-ReportJson {
    param([string]$Path)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            return ($raw | ConvertFrom-Json)
        }
        catch {
            if ($attempt -eq 3) { return $null }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

# Pure string manipulation, no System.IO.Path/Split-Path calls: used on
# both trusted script-set paths (module_metadata.file_path) and arbitrary
# LLM-written dependency-reference text, so this has to be safe for the
# latter. Path.GetFileName/GetFileNameWithoutExtension both validate their
# ENTIRE input against .NET's illegal-filename-character set (confirmed by
# testing -- a dependency reference containing one of those characters
# anywhere throws "Illegal characters in path" before ever returning a
# segment), and Split-Path separately throws "Cannot find a provider" on a
# bare colon-prefixed token (e.g. a PHP "PEAR:DB"-style reference) by
# trying to resolve it as a PSDrive name. Manual LastIndexOfAny/Substring
# never validates content, so it can't throw on any input.
function Get-LastPathSegment {
    param([string]$Text)
    $idx = $Text.LastIndexOfAny(@('/', '\'))
    if ($idx -ge 0) { return $Text.Substring($idx + 1) }
    return $Text
}
function Remove-LastExtension {
    param([string]$Text)
    $idx = $Text.LastIndexOf('.')
    if ($idx -gt 0) { return $Text.Substring(0, $idx) }
    return $Text
}

# ---------------- Pass 1: build the file index ----------------

$files = Get-ChildItem -LiteralPath $OutputsRoot -Recurse -Filter "*.json" -File -ErrorAction SilentlyContinue
$byExactPath = @{}
$byBasenameExt = @{}
$byBasenameNoExt = @{}
$reports = @{}   # file_path -> parsed report, kept for pass 2 so we don't re-read from disk

function Add-IndexEntry {
    param([hashtable]$Index, [string]$Key, [string]$Value)
    if (-not $Key) { return }
    $k = $Key.ToLowerInvariant()
    if (-not $Index.ContainsKey($k)) { $Index[$k] = New-Object System.Collections.Generic.List[string] }
    if ($Index[$k] -notcontains $Value) { $Index[$k].Add($Value) }
}

foreach ($file in $files) {
    $parsed = Read-ReportJson -Path $file.FullName
    if (-not $parsed -or -not $parsed.module_metadata -or -not $parsed.module_metadata.file_path) { continue }
    $filePath = $parsed.module_metadata.file_path
    if ($reports.ContainsKey($filePath)) { continue }  # defensive: shouldn't happen, file_path should be unique
    $reports[$filePath] = $parsed

    $basenameExt = Get-LastPathSegment $filePath
    $basenameNoExt = Remove-LastExtension $basenameExt
    Add-IndexEntry -Index $byExactPath -Key $filePath -Value $filePath
    Add-IndexEntry -Index $byBasenameExt -Key $basenameExt -Value $filePath
    Add-IndexEntry -Index $byBasenameNoExt -Key $basenameNoExt -Value $filePath
}

# ---------------- Pass 2: resolve file-to-file edges ----------------

function Resolve-DependencyReference {
    param([string]$Reference, [string]$SelfPath)
    $ref = $Reference.Trim().Trim('"').Trim("'")
    if (-not $ref) { return $null }
    $refLower = $ref.ToLowerInvariant()
    $selfLower = $SelfPath.ToLowerInvariant()
    $selfBasenameNoExtLower = (Remove-LastExtension (Get-LastPathSegment $SelfPath)).ToLowerInvariant()
    if ($refLower -eq $selfLower -or $refLower -eq $selfBasenameNoExtLower) { return $null }  # self-reference

    $refBasenameExt = (Get-LastPathSegment $ref).ToLowerInvariant()
    $refBasenameNoExt = Remove-LastExtension $refBasenameExt

    foreach ($tier in @(
        @{ Index = $byExactPath; Key = $refLower },
        @{ Index = $byBasenameExt; Key = $refBasenameExt },
        @{ Index = $byBasenameNoExt; Key = $refBasenameNoExt }
    )) {
        if ($tier.Index.ContainsKey($tier.Key)) {
            $candidates = @($tier.Index[$tier.Key] | Where-Object { $_.ToLowerInvariant() -ne $selfLower })
            if ($candidates.Count -eq 1) { return [PSCustomObject]@{ Status = "resolved"; Reference = $ref; Candidates = $candidates } }
            if ($candidates.Count -gt 1) { return [PSCustomObject]@{ Status = "ambiguous"; Reference = $ref; Candidates = $candidates } }
        }
    }
    return [PSCustomObject]@{ Status = "unresolved"; Reference = $ref; Candidates = @() }
}

$fileEdges = @{}          # file_path -> list of resolution results (file-to-file)
$tableMap = @{}           # lowercased target_entity -> @{ DisplayName; Files = list of @{Path; OperationType} }

foreach ($filePath in $reports.Keys) {
    $parsed = $reports[$filePath]
    $deps = @($parsed.dependencies_and_integrations.internal_module_dependencies)
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($dep in $deps) {
        if (-not $dep -or $dep -isnot [string]) { continue }
        $result = Resolve-DependencyReference -Reference $dep -SelfPath $filePath
        if ($result) { $results.Add($result) }
    }
    $fileEdges[$filePath] = $results

    foreach ($interaction in @($parsed.dependencies_and_integrations.database_interactions)) {
        if (-not $interaction -or -not $interaction.target_entity) { continue }
        $entity = ([string]$interaction.target_entity).Trim()
        if (-not $entity) { continue }
        $key = $entity.ToLowerInvariant()
        if (-not $tableMap.ContainsKey($key)) {
            $tableMap[$key] = [PSCustomObject]@{ DisplayName = $entity; Files = New-Object System.Collections.Generic.List[object] }
        }
        $tableMap[$key].Files.Add([PSCustomObject]@{ Path = $filePath; OperationType = $interaction.operation_type })
    }
}

# ---------------- Output ----------------

New-Item -ItemType Directory -Force -Path $GraphOutDir | Out-Null

$graphOut = [PSCustomObject]@{
    generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    files_processed = $reports.Count
    file_to_file = @($fileEdges.Keys | ForEach-Object {
        [PSCustomObject]@{ path = $_; dependencies = $fileEdges[$_] }
    })
    file_to_table = @($tableMap.Keys | ForEach-Object {
        [PSCustomObject]@{ table = $tableMap[$_].DisplayName; files = $tableMap[$_].Files }
    })
}
$graphPath = Join-Path $GraphOutDir "graph.json"
($graphOut | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $graphPath -Encoding UTF8

# ---------------- Summary report ----------------

$allResults = @($fileEdges.Values | ForEach-Object { $_ })
$resolvedCount = @($allResults | Where-Object { $_.Status -eq "resolved" }).Count
$ambiguousCount = @($allResults | Where-Object { $_.Status -eq "ambiguous" }).Count
$unresolvedCount = @($allResults | Where-Object { $_.Status -eq "unresolved" }).Count

$fanOut = @{}
$fanIn = @{}
foreach ($filePath in $fileEdges.Keys) {
    $resolvedEdges = @($fileEdges[$filePath] | Where-Object { $_.Status -eq "resolved" })
    $fanOut[$filePath] = $resolvedEdges.Count
    foreach ($edge in $resolvedEdges) {
        $target = $edge.Candidates[0]
        if (-not $fanIn.ContainsKey($target)) { $fanIn[$target] = 0 }
        $fanIn[$target]++
    }
}

Write-Host ("--- Dependency graph report ({0}) ---" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
Write-Host ("Files processed        : {0}" -f $reports.Count)
Write-Host ("Dependency references  : {0}  (resolved {1}, ambiguous {2}, unresolved {3})" -f $allResults.Count, $resolvedCount, $ambiguousCount, $unresolvedCount)
Write-Host ("Tables found            : {0}" -f $tableMap.Count)
Write-Host ("Graph written to        : {0}" -f $graphPath)
Write-Host ""
Write-Host ("Top {0} files by fan-in (most depended-upon):" -f $TopN) -ForegroundColor Yellow
$fanIn.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopN | ForEach-Object {
    Write-Host ("  {0,4}  {1}" -f $_.Value, $_.Key)
}
Write-Host ""
Write-Host ("Top {0} files by fan-out (most dependencies):" -f $TopN) -ForegroundColor Yellow
$fanOut.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First $TopN | ForEach-Object {
    Write-Host ("  {0,4}  {1}" -f $_.Value, $_.Key)
}
Write-Host ""
Write-Host ("Top {0} tables by contributing file count:" -f $TopN) -ForegroundColor Yellow
$tableMap.GetEnumerator() | Sort-Object -Property { $_.Value.Files.Count } -Descending | Select-Object -First $TopN | ForEach-Object {
    Write-Host ("  {0,4}  {1}" -f $_.Value.Files.Count, $_.Value.DisplayName)
}
