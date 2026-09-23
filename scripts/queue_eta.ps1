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

# Relaunch under PowerShell 7 when available -- see the matching block in
# run_analysis_pipeline_parallel.ps1 for why (Windows PowerShell 5.1's
# ConvertFrom-Json can't reliably parse manifest.json once it grows large --
# this script hit that exact failure directly on 2026-09-22). A no-op when
# already running under PS7, including when called in-process by an
# already-relaunched run_analysis_pipeline_parallel.ps1.
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

# Retry on a locked-file IOException (AV/indexer, or this read landing in the
# split-second around a worker's atomic File.Replace of the same manifest --
# see Write-Utf8NoBom/Read-Manifest in run_analysis_pipeline.ps1) or a JSON
# parse failure from an occasional torn read. Either clears within
# milliseconds once the other write finishes.
$manifest = $null
$maxAttempts = 5
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        break
    }
    catch {
        if ($attempt -eq $maxAttempts) { throw }
        Start-Sleep -Milliseconds (100 * $attempt)
    }
}

$completed = @($manifest.files | Where-Object { $_.status -eq "completed" -and $_.token_usage.run_total_elapsed_seconds -gt 0 })
$blocked = @($manifest.files | Where-Object { $_.status -eq "blocked" })
$inProgress = @($manifest.files | Where-Object { $_.status -eq "in_progress" })
$queued = @($manifest.files | Where-Object { $_.status -eq "queued" })
$remaining = @($manifest.files | Where-Object { $_.status -in @("queued", "blocked", "in_progress") })

Write-Host ("--- Analysis queue progress ({0}) ---" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
Write-Host ("Completed    : {0}" -f $completed.Count)
Write-Host ("Remaining    : {0}  (queued {1}, blocked {2}, in_progress {3})" -f $remaining.Count, $queued.Count, $blocked.Count, $inProgress.Count)

# Average elapsed_seconds AND token usage per stage, drawn from every file in
# the manifest (any status) that has a recorded sample for that specific
# stage - not just "completed" files, since a file can have solid timing for
# early stages while still queued/in-progress on a later one. Token stats are
# collected in this same pass rather than a second iteration over
# $manifest.files. Total tokens consumed is summed from these per-stage
# entries rather than each file's own run_total_tokens: backfill_new_stage.ps1
# zeroes run_total_tokens at rewind time, so for a backfilled file it only
# reflects the most recent completion pass -- summing per-stage entries
# (which backfill explicitly leaves untouched for stages before the rewind
# point) captures the file's complete historical token cost instead.
$stageAvgSeconds = @{}
$stageAvgTokens = @{}
$stageTotalTokens = @{}
$stageTotalCompletionTokens = @{}
$stageTotalElapsedForThroughput = @{}
$totalPromptTokens = 0L
$totalCompletionTokens = 0L
$modelTokenTotals = @{}
foreach ($stageName in $StageAgents) {
    $secondsSamples = @()
    $tokenSamples = @()
    $totalTokensThisStage = 0L
    $completionTokensThisStage = 0L
    $elapsedForThroughputThisStage = 0.0
    foreach ($entry in $manifest.files) {
        $agent = $entry.token_usage.agents.($stageName)
        if ($agent -and [double]$agent.elapsed_seconds -gt 0) {
            $secondsSamples += [double]$agent.elapsed_seconds
        }
        if ($agent -and [double]$agent.total_tokens -gt 0) {
            $tokenSamples += [double]$agent.total_tokens
            $totalTokensThisStage += [int64]$agent.total_tokens
            $completionTokensThisStage += [int64]$agent.completion_tokens
            $totalPromptTokens += [int64]$agent.prompt_tokens
            $totalCompletionTokens += [int64]$agent.completion_tokens
            if ([double]$agent.elapsed_seconds -gt 0) { $elapsedForThroughputThisStage += [double]$agent.elapsed_seconds }
            if ($agent.model_name) {
                if (-not $modelTokenTotals.ContainsKey($agent.model_name)) { $modelTokenTotals[$agent.model_name] = 0L }
                $modelTokenTotals[$agent.model_name] += [int64]$agent.total_tokens
            }
        }
    }
    if ($secondsSamples.Count -gt 0) {
        $stageAvgSeconds[$stageName] = ($secondsSamples | Measure-Object -Average).Average
    }
    if ($tokenSamples.Count -gt 0) {
        $stageAvgTokens[$stageName] = ($tokenSamples | Measure-Object -Average).Average
        $stageTotalTokens[$stageName] = $totalTokensThisStage
        $stageTotalCompletionTokens[$stageName] = $completionTokensThisStage
        $stageTotalElapsedForThroughput[$stageName] = $elapsedForThroughputThisStage
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

# Token-side counterpart to Get-RemainingSecondsEstimate, structurally
# identical (same last_completed_stage-derived start index, same
# per-remaining-stage summation with the same average/fallback logic) --
# kept as a separate function rather than a shared generic helper to match
# this script's existing plain, non-abstracted style.
function Get-RemainingTokensEstimate {
    param($Entry, [hashtable]$StageAvgTokens, [double]$FallbackAvgPerStage, [string[]]$Stages)
    $startIndex = 0
    if ($Entry.last_completed_stage) {
        $idx = [array]::IndexOf($Stages, $Entry.last_completed_stage)
        if ($idx -ge 0) { $startIndex = $idx + 1 }
    }
    $total = 0.0
    for ($i = $startIndex; $i -lt $Stages.Count; $i++) {
        $stageName = $Stages[$i]
        $total += if ($StageAvgTokens.ContainsKey($stageName)) { $StageAvgTokens[$stageName] } else { $FallbackAvgPerStage }
    }
    return $total
}

$fallbackAvgTokensPerStage = if ($stageAvgTokens.Count -gt 0) { ($stageAvgTokens.Values | Measure-Object -Average).Average } else { 0.0 }
$remainingTokensTotal = 0.0
foreach ($entry in $remaining) {
    $remainingTokensTotal += Get-RemainingTokensEstimate -Entry $entry -StageAvgTokens $stageAvgTokens -FallbackAvgPerStage $fallbackAvgTokensPerStage -Stages $StageAgents
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

Write-Host ""
Write-Host "--- Token usage ---" -ForegroundColor Cyan
if ($stageAvgTokens.Count -eq 0) {
    Write-Host "No recorded token usage yet." -ForegroundColor Yellow
}
else {
    $totalTokensConsumed = $totalPromptTokens + $totalCompletionTokens
    Write-Host ("Tokens so far     : {0:N0} total (prompt {1:N0} + completion {2:N0})" -f $totalTokensConsumed, $totalPromptTokens, $totalCompletionTokens)
    Write-Host ("Projected remaining tokens (queue) : {0:N0}" -f $remainingTokensTotal)
    Write-Host ""
    Write-Host "Per-stage token usage:" -ForegroundColor Cyan
    Write-Host ("  {0,-38} {1,10} {2,14} {3,16}" -f "Stage", "Avg/file", "Total", "Tok/sec (compl.)")
    foreach ($stageName in $StageAgents) {
        if (-not $stageAvgTokens.ContainsKey($stageName)) { continue }
        $throughput = if ($stageTotalElapsedForThroughput[$stageName] -gt 0) {
            $stageTotalCompletionTokens[$stageName] / $stageTotalElapsedForThroughput[$stageName]
        } else { 0.0 }
        Write-Host ("  {0,-38} {1,10:N0} {2,14:N0} {3,16:N1}" -f $stageName, $stageAvgTokens[$stageName], $stageTotalTokens[$stageName], $throughput)
    }

    if ($modelTokenTotals.Count -gt 1) {
        Write-Host ""
        Write-Host "Per-model token totals:" -ForegroundColor Cyan
        foreach ($modelName in $modelTokenTotals.Keys) {
            Write-Host ("  {0,-38} {1,14:N0}" -f $modelName, $modelTokenTotals[$modelName])
        }
    }
}
