# Estimates time-to-completion for the remaining analysis queue.
#
# Estimates per-stage from token_usage.agents.<stage>.elapsed_seconds,
# averaged across every file that has a recorded sample for that specific
# stage - not from a single blended per-file total. That distinction matters
# whenever "completed" files in the manifest don't all represent the same
# amount of work: a file backfilled onto a newly-added stage (see
# backfill_new_stage.ps1) reruns only the stages from that new stage onward,
# so its recorded run_total_elapsed_seconds covers a handful of stages, not
# the full chain - averaging that blindly against fresh full-chain
# completions understates how much work remains for everything still queued.
# Per-stage averaging sidesteps this entirely: each stage's average only
# ever mixes samples of that one stage, regardless of how much of the rest
# of the chain any given file happened to also run in the same pass.
#
# Usage:
#   .\queue_eta.ps1                 # report against the live manifest, 1 worker
#   .\queue_eta.ps1 -Workers 2      # divide the remaining time across N concurrent workers
#   .\queue_eta.ps1 -ManifestPath ".analysis-state\queue\manifest.json"

param(
    [string]$ManifestPath = "",
    [int]$Workers = 1
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
if (-not $ManifestPath) { $ManifestPath = Join-Path $Root ".analysis-state\queue\manifest.json" }

# The stage roster lives in one shared file so this script can't drift out
# of sync with the actual execution chain in run_analysis_pipeline.ps1 - this
# used to be a third independent hardcoded copy (missing narrative_writer
# entirely, which silently threw off every ETA estimate once that stage was
# added, since a file mid-chain looked closer to done than it actually was).
. (Join-Path $PSScriptRoot "pipeline_stages.ps1")
$StageAgents = Get-AllAgentNames | Select-Object -Skip 1

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "No manifest found at $ManifestPath. Run generate_analysis_queue.ps1 first."
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$completed = @($manifest.files | Where-Object { $_.status -eq "completed" -and $_.token_usage.run_total_elapsed_seconds -gt 0 })
$blocked = @($manifest.files | Where-Object { $_.status -eq "blocked" })
$inProgress = @($manifest.files | Where-Object { $_.status -eq "in_progress" })
$queued = @($manifest.files | Where-Object { $_.status -eq "queued" })
$remaining = @($manifest.files | Where-Object { $_.status -in @("queued", "blocked", "in_progress") })

Write-Host ("--- Analysis queue progress ({0}) ---" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
Write-Host ("Completed    : {0}" -f $completed.Count)
Write-Host ("Remaining    : {0}  (queued {1}, blocked {2}, in_progress {3})" -f $remaining.Count, $queued.Count, $blocked.Count, $inProgress.Count)

# Average elapsed_seconds per stage, drawn from every file in the manifest
# (any status) that has a recorded sample for that specific stage - not just
# "completed" files, since a file can have solid timing for early stages
# while still queued/in-progress on a later one.
$stageAvgSeconds = @{}
foreach ($stageName in $StageAgents) {
    $samples = @()
    foreach ($entry in $manifest.files) {
        $agent = $entry.token_usage.agents.($stageName)
        if ($agent -and [double]$agent.elapsed_seconds -gt 0) {
            $samples += [double]$agent.elapsed_seconds
        }
    }
    if ($samples.Count -gt 0) {
        $stageAvgSeconds[$stageName] = ($samples | Measure-Object -Average).Average
    }
}

if ($stageAvgSeconds.Count -eq 0) {
    Write-Host "No stages have recorded processing time yet -- can't estimate an ETA." -ForegroundColor Yellow
    return
}

# Stages with no recorded sample at all (e.g. a brand-new stage before
# anything has run it even once) fall back to the average of whatever
# stages do have samples, rather than being silently skipped.
$fallbackAvgPerStage = ($stageAvgSeconds.Values | Measure-Object -Average).Average
$avgFullChainSeconds = 0.0
foreach ($stageName in $StageAgents) {
    $avgFullChainSeconds += if ($stageAvgSeconds.ContainsKey($stageName)) { $stageAvgSeconds[$stageName] } else { $fallbackAvgPerStage }
}

function Get-RemainingSecondsEstimate {
    param($Entry, [hashtable]$StageAvgSeconds, [double]$FallbackAvgPerStage, [string[]]$Stages)
    $startIndex = 0
    if ($Entry.last_completed_stage) {
        $idx = [array]::IndexOf($Stages, $Entry.last_completed_stage)
        if ($idx -ge 0) { $startIndex = $idx + 1 }
    }
    $total = 0.0
    for ($i = $startIndex; $i -lt $Stages.Count; $i++) {
        $stageName = $Stages[$i]
        $total += if ($StageAvgSeconds.ContainsKey($stageName)) { $StageAvgSeconds[$stageName] } else { $FallbackAvgPerStage }
    }
    return $total
}

$remainingSecondsTotal = 0.0
foreach ($entry in $remaining) {
    $remainingSecondsTotal += Get-RemainingSecondsEstimate -Entry $entry -StageAvgSeconds $stageAvgSeconds -FallbackAvgPerStage $fallbackAvgPerStage -Stages $StageAgents
}

$effectiveWorkers = [Math]::Max(1, $Workers)
$etaSeconds = $remainingSecondsTotal / $effectiveWorkers
$etaTimespan = [TimeSpan]::FromSeconds($etaSeconds)
$etaCompletionUtc = (Get-Date).ToUniversalTime().AddSeconds($etaSeconds)

Write-Host ("Avg time/file (full {0}-stage chain, from per-stage samples) : {1:N1} min ({2:N0} sec)" -f $StageAgents.Count, ($avgFullChainSeconds / 60), $avgFullChainSeconds)
Write-Host ("Workers assumed                  : {0}" -f $effectiveWorkers)
Write-Host ("Estimated remaining time         : {0}d {1}h {2}m" -f $etaTimespan.Days, $etaTimespan.Hours, $etaTimespan.Minutes)
Write-Host ("Estimated completion (UTC)       : {0:yyyy-MM-dd HH:mm}" -f $etaCompletionUtc)
Write-Host ("Estimated completion (local)     : {0:yyyy-MM-dd HH:mm}" -f $etaCompletionUtc.ToLocalTime())
