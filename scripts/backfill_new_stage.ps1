# Propagates a newly-added pipeline stage across files that already
# completed the full chain before that stage existed - the operation
# add-narrative-writer-agent performed by hand (twice, hitting a BOM bug and
# a missing-fields bug along the way) when narrative_writer was added.
#
# For every manifest entry with status "completed" that has no recorded
# usage yet for -NewStageName, this rewinds last_completed_stage (in both
# its state file and its manifest entry) to the stage immediately preceding
# the new one in the shared registry, sets status back to "queued", and
# zeroes its run-total counters - so the next pipeline run naturally resumes
# each file right at the new stage, reusing every earlier stage's saved
# intermediate rather than reprocessing from scratch. Per-agent history for
# stages before the rewind point is left exactly as recorded.
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

param(
    [Parameter(Mandatory = $true)][string]$NewStageName,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $RepoRoot ".analysis-state"
$ManifestPath = Join-Path $StateRoot "queue\manifest.json"

. (Join-Path $PSScriptRoot "pipeline_stages.ps1")

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
    if (Test-Path -LiteralPath $Path) {
        $backupPath = "$Path.bak-$PID"
        [System.IO.File]::Replace($tempPath, $Path, $backupPath)
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $tempPath -Destination $Path
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
        (-not $_.token_usage.agents.($NewStageName) -or -not $_.token_usage.agents.($NewStageName).model_name)
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
