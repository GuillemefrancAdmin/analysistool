# Rewinds already-"completed" files to just before -NewStageName so the next
# pipeline run re-executes that one stage, reusing every earlier stage's
# saved intermediate rather than reprocessing from scratch. Two distinct
# uses:
#
#   1. Propagating a newly-added stage across files that completed the full
#      chain before that stage existed - the operation add-narrative-writer-
#      agent performed by hand (twice, hitting a BOM bug and a missing-fields
#      bug along the way) when narrative_writer was added. By default, only
#      files with no recorded usage yet for -NewStageName are matched.
#
#   2. Force re-running a stage whose PROMPT/behavior changed after files
#      already completed it once (e.g. fix-architecture-spec-synthesis: the
#      final-synthesis prompt was fixed after 1,578 files had already run it
#      with the old, buggy prompt). Pass -EvenIfAlreadyRun to match every
#      "completed" file regardless of whether -NewStageName already has a
#      recorded result for it - the default match-only-if-never-run
#      condition would otherwise select nothing, since every file already
#      has *a* result for that stage, just a low-quality one.
#
# Either way, this rewinds last_completed_stage (in both the state file and
# the manifest entry) to the stage immediately preceding -NewStageName in
# the shared registry, sets status back to "queued", and zeroes the file's
# run-total counters. Per-agent history for stages before the rewind point -
# including -NewStageName's own now-stale entry under -EvenIfAlreadyRun - is
# left exactly as recorded until that stage actually reruns and overwrites
# its own entry.
#
# Safe to run while other files are still being actively processed: matched
# files are, by definition, already "completed" (a live worker only holds
# "in_progress" files), and the manifest update is done under the same
# cross-process mutex run_analysis_pipeline.ps1's Save-Manifest uses, so it
# can't interleave with a live worker's own manifest write.
#
# Usage:
#   .\backfill_new_stage.ps1 -NewStageName narrative_writer
#       # report-only: prints how many files would be touched, writes nothing
#   .\backfill_new_stage.ps1 -NewStageName narrative_writer -Force
#       # actually performs the rewind
#   .\backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun
#       # report-only: force-rewind mode, matches every completed file
#   .\backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun -Force
#       # actually re-queues every completed file for that stage alone

param(
    [Parameter(Mandatory = $true)][string]$NewStageName,
    [switch]$Force,
    [switch]$EvenIfAlreadyRun
)

# Relaunch under PowerShell 7 when available -- see the matching block in
# run_analysis_pipeline_parallel.ps1 for why (Windows PowerShell 5.1's
# ConvertFrom-Json can't reliably parse manifest.json once it grows large,
# and this script reads/rewrites the whole thing).
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) {
        $pwshExe = @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe"
            "$env:LOCALAPPDATA\Programs\PowerShell-7.6.6\pwsh.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if ($pwshExe) {
        # Forwarded via a small JSON bootstrap file + hashtable splat, not raw
        # -File command-line args: confirmed by testing that -File's own
        # argument parsing silently mangles array-typed parameters (space-
        # separated values drop everything after the first element; a single
        # comma-joined token doesn't get re-split into an array either).
        # JSON round-trips every bound parameter -- arrays, switches, scalars
        # -- exactly, then a real hashtable splat binds them correctly.
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
    Write-Host "WARNING: pwsh.exe (PowerShell 7) not found -- continuing under Windows PowerShell 5.1, which cannot reliably parse a large manifest.json." -ForegroundColor Yellow
}

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $RepoRoot ".analysis-state"
$ManifestPath = Join-Path $StateRoot "queue\manifest.json"

. (Join-Path $PSScriptRoot "pipeline_stages.ps1")

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    # Verify-and-retry the whole write: confirmed in practice (twice, on
    # manifest.json) that something external can inject a single stray
    # character into an otherwise-correct write -- see the matching, more
    # fully-commented version of this function in run_analysis_pipeline.ps1.
    $maxWriteAttempts = 3
    for ($writeAttempt = 1; $writeAttempt -le $maxWriteAttempts; $writeAttempt++) {
        $tempPath = "$Path.tmp-$PID"
        [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
        if (Test-Path -LiteralPath $Path) {
            $backupPath = "$Path.bak-$PID"
            $maxReplaceAttempts = 5
            for ($attempt = 1; $attempt -le $maxReplaceAttempts; $attempt++) {
                try {
                    [System.IO.File]::Replace($tempPath, $Path, $backupPath)
                    break
                }
                catch [System.IO.IOException] {
                    if ($attempt -eq $maxReplaceAttempts) { throw }
                    Start-Sleep -Milliseconds (100 * $attempt)
                }
            }
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item -LiteralPath $tempPath -Destination $Path
        }

        $actualContent = [System.IO.File]::ReadAllText($Path, $encoding)
        if ($actualContent -ceq $Content) { return }
        if ($writeAttempt -eq $maxWriteAttempts) {
            throw "Write-Utf8NoBom: content read back from '$Path' didn't match what was written, even after $maxWriteAttempts attempts -- something external is altering this file during/after write."
        }
        Start-Sleep -Milliseconds (150 * $writeAttempt)
    }
}

# Full execution-order stage name list (matches run_analysis_pipeline.ps1's
# own $StageAgents scope: no file_queue_orchestrator_agent, since that's not
# a last_completed_stage value any file ever records).
$OrderedStageNames = @($SanitizerStageName) + ($PipelineStages | ForEach-Object { $_.Name }) + @($FinalSynthesisStageName)

$newStageIndex = [array]::IndexOf($OrderedStageNames, $NewStageName)
if ($newStageIndex -lt 0) {
    throw "'$NewStageName' is not a known stage name. Known stages: $($OrderedStageNames -join ', ')"
}
if ($newStageIndex -eq 0) {
    throw "'$NewStageName' is the first stage in the chain; there is no preceding stage to rewind to."
}
$precedingStageName = $OrderedStageNames[$newStageIndex - 1]

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "No manifest found at $ManifestPath"
}

$mutex = New-Object System.Threading.Mutex($false, "AnalysisPipelineManifestLock")
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(60000) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw "Timed out waiting for the cross-process manifest lock." }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $targets = $manifest.files | Where-Object {
        $_.status -eq "completed" -and
        ($EvenIfAlreadyRun -or -not $_.token_usage.agents.($NewStageName) -or -not $_.token_usage.agents.($NewStageName).model_name)
    }

    Write-Host "Stage '$NewStageName' -> rewinding to '$precedingStageName'."
    Write-Host "Files that would be touched: $($targets.Count) (of $($manifest.files.Count) total)"

    if (-not $Force) {
        Write-Host "Report-only (no -Force passed). Nothing written."
        return
    }

    $nowStamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $touched = 0
    $missingState = @()
    foreach ($entry in $targets) {
        $statePath = Join-Path $StateRoot ($entry.state_file -replace '^\.analysis-state[\\/]', '' -replace '/', '\')
        if (-not (Test-Path -LiteralPath $statePath)) {
            $missingState += $entry.path
            continue
        }
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.status = "queued"
        $state.last_completed_stage = $precedingStageName
        $state.updated_at = $nowStamp
        $state.token_usage.run_total_tokens = 0
        $state.token_usage.run_total_elapsed_seconds = 0
        Write-Utf8NoBom -Path $statePath -Content ($state | ConvertTo-Json -Depth 12)

        $entry.status = "queued"
        $entry.last_completed_stage = $precedingStageName
        $entry.last_updated = $nowStamp
        $entry.token_usage.run_total_tokens = 0
        $entry.token_usage.run_total_elapsed_seconds = 0
        $touched++
    }

    Write-Utf8NoBom -Path $ManifestPath -Content ($manifest | ConvertTo-Json -Depth 12)
    Write-Host "Rewound $touched file(s)."
    if ($missingState.Count -gt 0) {
        Write-Host "Warning: $($missingState.Count) matched entries had no state file on disk and were skipped:" -ForegroundColor Yellow
        $missingState | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
    }
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
