# Orchestrates several instances of run_analysis_pipeline.ps1 against the
# same queue, one worker per GPU. Ollama pins a whole server *process* to a
# GPU via CUDA_VISIBLE_DEVICES at launch (unlike LM Studio, which couldn't
# guarantee physical GPU placement per model identifier -- confirmed during
# migration), so each worker gets its own dedicated `ollama serve` instance
# on its own port, started by this script before any workers launch. Each
# worker is then its own background job (a real child process, so the
# workers make concurrent HTTP calls without blocking each other). There is
# no fixed per-worker slice of the queue: every worker atomically claims its
# next file from the shared manifest as it goes (run_analysis_pipeline.ps1's
# Request-NextFile), so a worker that finishes faster than its peers -- a
# smaller file, a faster GPU, or just finishing earlier -- immediately helps
# with whatever they haven't gotten to yet instead of exiting; its
# merge-safe Save-Manifest keeps their progress writes from clobbering each
# other. This script just bootstraps the instances, launches, streams, and
# waits.
#
# When to use: the normal way to run the pipeline on a multi-GPU machine (for a
# single worker, run_analysis_pipeline.ps1 directly). Stop a run with
# stop_analysis_pipeline.ps1.
#
# Usage:
#   .\run_analysis_pipeline_parallel.ps1
#       # starts one Ollama instance per -CudaDevices entry (default 2,
#       # pinned to each physical GPU) and processes the entire remaining
#       # queue split across them.
#   .\run_analysis_pipeline_parallel.ps1 -Limit 20
#       # cap each worker at 20 files instead of draining the whole queue.
#   .\run_analysis_pipeline_parallel.ps1 -DryRun
#       # show each worker's partition without calling any model.
#   .\run_analysis_pipeline_parallel.ps1 -EtaEverySeconds 30
#       # print progress/ETA (via queue_eta.ps1) every 30s while running
#       # instead of the default 60s; the manifest is updated after every
#       # file, so this reflects live progress, not just the final summary.
#   .\run_analysis_pipeline_parallel.ps1 -NoAutoStart
#       # skip the Ollama instance bootstrap below and assume both ports
#       # already have a dedicated instance running.
#   .\run_analysis_pipeline_parallel.ps1 -StaggerSeconds 30
#       # wait longer between launching each worker (default 15s) -- give
#       # this more room if manifest.json keeps growing and 15s stops being
#       # enough gap between workers' startup Read-Manifest calls.
#   .\run_analysis_pipeline_parallel.ps1 -WorkerRestartDelaySeconds 60 -MaxWorkerRestarts 5
#       # if a worker's job dies outright (crashed host process), relaunch
#       # it with the same partition after this long, up to this many times
#       # per worker, instead of leaving that partition unworked for the
#       # rest of the run.

param(
    [int]$Limit = 0,
    [string]$Model = "llama3.1:8b",
    [int[]]$OllamaPorts = @(11435, 11436),
    # CUDA_VISIBLE_DEVICES value per worker, index-matched to -OllamaPorts.
    # VERIFIED REVERSED on this machine: CUDA device "1" landed on physical
    # GPU 0 (nvidia-smi index 0), CUDA device "0" landed on physical GPU 1 --
    # a known CUDA-vs-nvidia-smi device-ordering quirk, not a bug. Re-verify
    # with nvidia-smi before/after loading if this ever runs on different
    # hardware -- don't assume "0" means the first card.
    [string[]]$CudaDevices = @("1", "0"),
    [string]$OllamaModelsPath = "E:\ollama\models",
    [double]$Temperature = 0.2,
    # See run_analysis_pipeline.ps1's default: prevents a stage that never
    # emits a stop token from running away to the context limit.
    [int]$MaxTokensPerStage = 4096,
    [int]$TimeoutSec = 86400,
    [int]$MaxContentChars = 0,
    [int]$MaxFinalContextChars = 160000,
    [switch]$DryRun,
    [int]$PollSeconds = 2,
    [int]$EtaEverySeconds = 60,
    [switch]$NoAutoStart,
    [int]$HeartbeatSeconds = 5,
    # Delay between launching each worker. Without this, all workers call
    # Read-Manifest (a full JSON parse/reserialize of manifest.json, which
    # grows into the tens of MB over a long run) within the same instant at
    # startup -- confirmed in practice as the trigger for a worker's host
    # powershell.exe process dying with a raw clr.dll access violation
    # (0xc0000005) before it even printed its first log line. Staggering
    # the launches spreads that one-time heavy parse out instead of letting
    # every worker hit it simultaneously.
    [int]$StaggerSeconds = 15,
    # If a worker's job dies outright (its host powershell.exe process
    # crashed -- the clr.dll access violation case, or anything else that
    # takes the whole process down rather than surfacing as a normal
    # PowerShell error), relaunch it with the same -WorkerIndex/-WorkerCount
    # partition after this many seconds instead of leaving that partition
    # permanently unworked for the rest of the run. Mirrors the wait-then-
    # restart pattern run_analysis_pipeline.ps1 already uses for a crashed
    # Ollama instance (-OllamaDownWaitSeconds).
    [int]$WorkerRestartDelaySeconds = 30,
    # Cap on relaunches per worker, so a deterministic/repeating crash (e.g.
    # a genuinely too-large manifest.json) can't loop forever burning GPU
    # time instead of ever finishing -- it gives up and reports Failed after
    # this many restarts, same as before this feature existed.
    [int]$MaxWorkerRestarts = 3
)

# Relaunch under PowerShell 7 when available, before doing anything else -- see
# pipeline_common.ps1 for why (manifest.json grows into the tens of MB and 5.1's
# ConvertFrom-Json is both far slower on it and, past a certain size, fails
# outright with a garbled dump instead of a clean error -- confirmed 2026-09-22)
# and for how the parameter forwarding works. Every worker this orchestrator
# launches via Start-Job inherits whichever engine is currently running, so
# relaunching here also fixes every worker's own manifest reads.
. (Join-Path $PSScriptRoot "pipeline_common.ps1")
Restart-UnderPowerShell7 -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -MissingPwshMessage "pwsh.exe (PowerShell 7) not found -- continuing under Windows PowerShell 5.1, which cannot reliably parse a large manifest.json. Install PowerShell 7 to avoid intermittent crashes/corruption."

$ErrorActionPreference = "Stop"

if ($OllamaPorts.Count -ne $CudaDevices.Count) {
    throw "-OllamaPorts ($($OllamaPorts.Count)) and -CudaDevices ($($CudaDevices.Count)) must have the same number of entries -- one pair per worker."
}

$Root = Split-Path -Parent $PSScriptRoot
$WorkerScript = Join-Path $PSScriptRoot "run_analysis_pipeline.ps1"
$ManifestPath = Join-Path $Root ".analysis-state\queue\manifest.json"

if (-not (Test-Path -LiteralPath $WorkerScript)) {
    throw "Worker script not found at $WorkerScript"
}

function Test-OllamaServerUp {
    param([string]$BaseUrl)
    try {
        $base = $BaseUrl -replace '/v1/?$', ''
        Invoke-RestMethod -Method Get -Uri "$base/api/tags" -TimeoutSec 5 | Out-Null
        return $true
    }
    catch { return $false }
}

# With $ErrorActionPreference = "Stop" (set above at script scope), a native
# exe's stderr output -- even ollama's own benign status/success text --
# becomes a terminating PowerShell error the moment PowerShell turns it into
# a NativeCommandError, REGARDLESS of where the stream is redirected
# (*> $null does not prevent this in Windows PowerShell 5.1 -- confirmed by
# hitting this exact crash, first with the lms CLI and again with ollama).
# What actually matters is $ErrorActionPreference at the time the native
# command runs, so this locally overrides it to "SilentlyContinue" for the
# call and restores it afterward; success/failure is read from
# $LASTEXITCODE, not the streams.
function Invoke-OllamaCommand {
    param([string[]]$ArgList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        & ollama @ArgList *> $null
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    return $LASTEXITCODE
}

function Start-OllamaInstanceIfNeeded {
    param([string]$BaseUrl, [string]$CudaDevice, [string]$ModelsPath, [string]$ModelKey, [int]$TimeoutSeconds = 60)
    if (-not (Test-OllamaServerUp -BaseUrl $BaseUrl)) {
        $bareHost = $BaseUrl -replace '^https?://', '' -replace '/v1/?$', ''
        Write-Host "Starting Ollama instance at $BaseUrl (CUDA_VISIBLE_DEVICES=$CudaDevice) ..." -ForegroundColor Yellow
        $prevCuda = $env:CUDA_VISIBLE_DEVICES
        $prevHost = $env:OLLAMA_HOST
        $prevModels = $env:OLLAMA_MODELS
        try {
            if ($CudaDevice) { $env:CUDA_VISIBLE_DEVICES = $CudaDevice }
            $env:OLLAMA_HOST = $bareHost
            if ($ModelsPath) { $env:OLLAMA_MODELS = $ModelsPath }
            Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden | Out-Null
        }
        finally {
            if ($null -eq $prevCuda) { Remove-Item Env:\CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue } else { $env:CUDA_VISIBLE_DEVICES = $prevCuda }
            if ($null -eq $prevHost) { Remove-Item Env:\OLLAMA_HOST -ErrorAction SilentlyContinue } else { $env:OLLAMA_HOST = $prevHost }
            if ($null -eq $prevModels) { Remove-Item Env:\OLLAMA_MODELS -ErrorAction SilentlyContinue } else { $env:OLLAMA_MODELS = $prevModels }
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-OllamaServerUp -BaseUrl $BaseUrl) { break }
            Start-Sleep -Seconds 2
        }
        if (-not (Test-OllamaServerUp -BaseUrl $BaseUrl)) {
            throw "Ollama instance did not come up at $BaseUrl after starting it."
        }
    }
    Write-Host "Pre-warming '$ModelKey' on $BaseUrl ..." -ForegroundColor Yellow
    $bareBase = $BaseUrl -replace '/v1/?$', ''
    try {
        Invoke-RestMethod -Method Post -Uri "$bareBase/api/generate" -TimeoutSec 300 -ContentType "application/json" `
            -Body (@{ model = $ModelKey; prompt = "hi"; stream = $false } | ConvertTo-Json) | Out-Null
    }
    catch {
        Write-Host "  pre-warm request failed (continuing anyway): $($_.Exception.Message)" -ForegroundColor Red
    }
}

$workerCount = $OllamaPorts.Count
$WorkerUrls = @($OllamaPorts | ForEach-Object { "http://127.0.0.1:$_/v1" })

if (-not $NoAutoStart -and -not $DryRun) {
    for ($i = 0; $i -lt $workerCount; $i++) {
        Start-OllamaInstanceIfNeeded -BaseUrl $WorkerUrls[$i] -CudaDevice $CudaDevices[$i] -ModelsPath $OllamaModelsPath -ModelKey $Model
    }
}

Write-Host "Launching $workerCount worker(s), one per GPU:" -ForegroundColor Cyan
for ($i = 0; $i -lt $workerCount; $i++) { Write-Host "  [$i] $Model on $($WorkerUrls[$i]) (CUDA_VISIBLE_DEVICES=$($CudaDevices[$i]))" }

function Start-Worker {
    param([int]$Index, [hashtable]$WorkerParams)
    return Start-Job -Name "analysis-worker-$Index" -ScriptBlock {
        param($ScriptPath, $ParamsTable)
        & $ScriptPath @ParamsTable
    } -ArgumentList $WorkerScript, $WorkerParams
}

$jobEntries = @()
for ($i = 0; $i -lt $workerCount; $i++) {
    $workerParams = @{
        Limit                 = $Limit
        OllamaUrl             = $WorkerUrls[$i]
        Model                 = $Model
        CudaVisibleDevices    = $CudaDevices[$i]
        OllamaModelsPath      = $OllamaModelsPath
        Temperature           = $Temperature
        MaxTokensPerStage     = $MaxTokensPerStage
        TimeoutSec            = $TimeoutSec
        MaxContentChars       = $MaxContentChars
        MaxFinalContextChars  = $MaxFinalContextChars
        DryRun                = [bool]$DryRun
        WorkerIndex           = $i
        WorkerCount           = $workerCount
        HeartbeatSeconds      = $HeartbeatSeconds
    }
    $job = Start-Worker -Index $i -WorkerParams $workerParams

    $jobEntries += [pscustomobject]@{
        Index          = $i
        Model          = $Model
        BaseUrl        = $WorkerUrls[$i]
        CudaDevice     = $CudaDevices[$i]
        WorkerParams   = $workerParams
        Job            = $job
        LastState      = $job.State
        Drained        = $false
        RestartCount   = 0
        PendingRetryAt = $null
        GaveUp         = $false
    }

    if ($StaggerSeconds -gt 0 -and $i -lt $workerCount - 1) {
        Start-Sleep -Seconds $StaggerSeconds
    }
}

Write-Host ""
Write-Host "Workers running. Streaming output below (this window can be closed" -ForegroundColor Cyan
Write-Host "without stopping the workers; reattach with Get-Job / Receive-Job)." -ForegroundColor Cyan
Write-Host ""

function Drain-JobOutput {
    param($Entries)
    foreach ($entry in $Entries) {
        # Once a job reaches a terminal state (e.g. its host process crashed --
        # observed in practice as a raw AccessViolationException taking down
        # the whole worker process), Receive-Job keeps re-surfacing the SAME
        # terminating error via -ErrorVariable on every single call, unlike
        # normal output which drains once and is gone. Left unguarded, that
        # turns into the same "[Worker N] ERROR: ..." line repeating forever,
        # every poll cycle, for the rest of the run -- drowning out every
        # other worker's real output. Drain a dead job exactly once more after
        # it stops running (to catch any trailing output/the state-change
        # notice below), then leave it alone.
        if ($entry.Job.State -ne "Running" -and $entry.Drained) { continue }

        # No -Keep: each call drains only what's arrived since the last one, so
        # nothing needs to be manually deduped. (-Keep was tried first but a
        # PowerShell job-buffer quirk made it replay already-seen records on
        # every poll -- confirmed with a minimal repro -- which is what caused
        # the same lines to print over and over during a real run.)
        # No prefix added here: each worker already tags its own lines with
        # "[Worker N]" at the source (run_analysis_pipeline.ps1), which is what
        # actually needs to survive interleaving -- adding a second, differently
        # -numbered wrapper prefix here would just double-tag every line.
        # ErrorVariable (not just -ErrorAction SilentlyContinue) so a worker's
        # own error-stream output is still shown here instead of silently
        # dropped -- a worker that dies with an unhandled exception used to go
        # completely quiet with no visible reason until the *entire* parallel
        # run finished (which can be days away), because only the final
        # summary checked Job.State. This surfaces both the error content and
        # a State-change notice the moment it happens instead.
        $jobErrors = $null
        $new = @(Receive-Job -Job $entry.Job -ErrorVariable jobErrors -ErrorAction SilentlyContinue)
        foreach ($line in $new) { Write-Host $line }
        foreach ($err in $jobErrors) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Write-Host "[$timestamp] [Worker $($entry.Index + 1)] ERROR: $err" -ForegroundColor Red
        }

        if ($entry.Job.State -ne $entry.LastState) {
            if ($entry.Job.State -in @("Failed", "Stopped")) {
                $reason = $entry.Job.ChildJobs[0].JobStateInfo.Reason
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Write-Host "[$timestamp] [Worker $($entry.Index + 1)] job $($entry.Job.State)$(if ($reason) { ": $reason" })" -ForegroundColor Red
                if ($entry.RestartCount -lt $MaxWorkerRestarts) {
                    $entry.PendingRetryAt = (Get-Date).AddSeconds($WorkerRestartDelaySeconds)
                    Write-Host "[$timestamp] [Worker $($entry.Index + 1)] will relaunch its partition in ${WorkerRestartDelaySeconds}s (restart $($entry.RestartCount + 1)/$MaxWorkerRestarts)" -ForegroundColor Yellow
                }
                else {
                    $entry.GaveUp = $true
                    Write-Host "[$timestamp] [Worker $($entry.Index + 1)] giving up -- already relaunched $MaxWorkerRestarts time(s); its remaining partition is left queued/blocked for a future run" -ForegroundColor Red
                }
            }
            $entry.LastState = $entry.Job.State
        }

        if ($entry.Job.State -ne "Running") { $entry.Drained = $true }
    }
}

# Relaunches any worker whose job died and whose retry delay has elapsed, on
# its original -OllamaUrl/-CudaDevice. There's no partition to hand back --
# workers pull from the shared manifest as they go (Request-NextFile in
# run_analysis_pipeline.ps1), so the relaunched process just resumes claiming
# from wherever the queue stands, including its own now-stale in_progress
# file once that goes past -StaleInProgressSeconds. Only re-verifies/restarts
# the Ollama instance first when this script is managing instances at all
# (-NoAutoStart means "assume something else owns that lifecycle").
function Restart-DeadWorkers {
    param($Entries)
    foreach ($entry in $Entries) {
        if (-not $entry.PendingRetryAt) { continue }
        if ($entry.Job.State -eq "Running") { $entry.PendingRetryAt = $null; continue }
        if ((Get-Date) -lt $entry.PendingRetryAt) { continue }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "[$timestamp] [Worker $($entry.Index + 1)] relaunching ..." -ForegroundColor Yellow
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue

        if (-not $NoAutoStart -and -not $DryRun) {
            Start-OllamaInstanceIfNeeded -BaseUrl $entry.BaseUrl -CudaDevice $entry.CudaDevice -ModelsPath $OllamaModelsPath -ModelKey $entry.Model
        }

        $entry.Job = Start-Worker -Index $entry.Index -WorkerParams $entry.WorkerParams
        $entry.LastState = $entry.Job.State
        $entry.Drained = $false
        $entry.RestartCount++
        $entry.PendingRetryAt = $null
    }
}

$etaScript = Join-Path $PSScriptRoot "queue_eta.ps1"
$lastEtaAt = Get-Date

function Test-WorkerStillActive {
    param($Entry)
    return $Entry.Job.State -eq "Running" -or ($Entry.PendingRetryAt -and -not $Entry.GaveUp)
}

while (@($jobEntries | Where-Object { Test-WorkerStillActive $_ }).Count -gt 0) {
    Drain-JobOutput -Entries $jobEntries
    Restart-DeadWorkers -Entries $jobEntries

    if (-not $DryRun -and (Test-Path -LiteralPath $ManifestPath) -and
        ((Get-Date) - $lastEtaAt).TotalSeconds -ge $EtaEverySeconds) {
        Write-Host ""
        # queue_eta.ps1 already retries transient manifest-read failures
        # internally, but it's still just a progress print -- never let it
        # take down the orchestrator (and orphan the still-running worker
        # jobs) over a read that stays locked past its own retry budget.
        try {
            & $etaScript -ManifestPath $ManifestPath -Workers $workerCount
        }
        catch {
            Write-Host "  (ETA report skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow
        }
        Write-Host ""
        $lastEtaAt = Get-Date
    }

    Start-Sleep -Seconds $PollSeconds
}
Drain-JobOutput -Entries $jobEntries

Write-Host ""
Write-Host "--- Parallel run summary ---" -ForegroundColor Cyan
$anyFailed = $false
foreach ($entry in $jobEntries) {
    $state = $entry.Job.State
    $restartNote = if ($entry.RestartCount -gt 0) { " (restarted $($entry.RestartCount)x)" } else { "" }
    Write-Host "  Worker $($entry.Index + 1) ($($entry.Model)): $state$restartNote"
    if ($state -eq "Failed") {
        $anyFailed = $true
        Write-Host "    $($entry.Job.ChildJobs[0].JobStateInfo.Reason)" -ForegroundColor Red
        if ($entry.GaveUp) {
            Write-Host "    gave up after $MaxWorkerRestarts restart(s) -- rerun this script to pick up its remaining partition" -ForegroundColor Red
        }
    }
    Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
}

if (-not $DryRun -and (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host ""
    & (Join-Path $PSScriptRoot "queue_eta.ps1") -ManifestPath $ManifestPath -Workers $workerCount
}

if ($anyFailed) { exit 1 }
