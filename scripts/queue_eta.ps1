# Estimates time-to-completion for the remaining analysis queue, based on
# the actual per-file processing time (token_usage.run_total_elapsed_seconds)
# recorded for files that already finished. Files still queued/blocked/
# in_progress that already have a last_completed_stage get a prorated
# estimate (remaining stages / 9) instead of the full per-file average.
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

# Order matters: matches the actual execution chain in run_analysis_pipeline.ps1.
$StageAgents = @(
    "sanitizer_context_ingestion_agent",
    "business_domain_extractor",
    "source_ast_structural_mapper",
    "business_logic_extractor",
    "security_compliance_analyst",
    "performance_scalability_analyst",
    "test_validation_analyst",
    "diagram_designer_context_visualizer",
    "architecture_spec_writer"
)

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

if ($completed.Count -eq 0) {
    Write-Host "No completed files with recorded processing time yet -- can't estimate an ETA." -ForegroundColor Yellow
    return
}

$times = @($completed | ForEach-Object { [double]$_.token_usage.run_total_elapsed_seconds })
$avgSeconds = ($times | Measure-Object -Average).Average

function Get-RemainingSecondsEstimate {
    param($Entry, [double]$AvgTotalSeconds, [string[]]$Stages)
    if ($Entry.last_completed_stage) {
        $idx = [array]::IndexOf($Stages, $Entry.last_completed_stage)
        if ($idx -ge 0) {
            $fractionRemaining = ($Stages.Count - ($idx + 1)) / $Stages.Count
            return $AvgTotalSeconds * $fractionRemaining
        }
    }
    return $AvgTotalSeconds
}

$remainingSecondsTotal = 0.0
foreach ($entry in $remaining) {
    $remainingSecondsTotal += Get-RemainingSecondsEstimate -Entry $entry -AvgTotalSeconds $avgSeconds -Stages $StageAgents
}

$effectiveWorkers = [Math]::Max(1, $Workers)
$etaSeconds = $remainingSecondsTotal / $effectiveWorkers
$etaTimespan = [TimeSpan]::FromSeconds($etaSeconds)
$etaCompletionUtc = (Get-Date).ToUniversalTime().AddSeconds($etaSeconds)

Write-Host ("Avg time/file (of {0} completed) : {1:N1} min ({2:N0} sec)" -f $completed.Count, ($avgSeconds / 60), $avgSeconds)
Write-Host ("Workers assumed                  : {0}" -f $effectiveWorkers)
Write-Host ("Estimated remaining time         : {0}d {1}h {2}m" -f $etaTimespan.Days, $etaTimespan.Hours, $etaTimespan.Minutes)
Write-Host ("Estimated completion (UTC)       : {0:yyyy-MM-dd HH:mm}" -f $etaCompletionUtc)
Write-Host ("Estimated completion (local)     : {0:yyyy-MM-dd HH:mm}" -f $etaCompletionUtc.ToLocalTime())
