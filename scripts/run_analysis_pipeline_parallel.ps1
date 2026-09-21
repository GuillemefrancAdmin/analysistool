# Orchestrates several instances of run_analysis_pipeline.ps1 against the
# same queue, one worker per GPU. Ollama pins a whole server *process* to a
# GPU via CUDA_VISIBLE_DEVICES at launch (unlike LM Studio, which couldn't
# guarantee physical GPU placement per model identifier -- confirmed during
# migration), so each worker gets its own dedicated `ollama serve` instance
# on its own port, started by this script before any workers launch. Each
# worker is then its own background job (a real child process, so the
# workers make concurrent HTTP calls without blocking each other) with a
# distinct -WorkerIndex/-WorkerCount pair, so run_analysis_pipeline.ps1's
# own partitioning keeps the workers from picking up the same file, and its
# merge-safe Save-Manifest keeps their progress writes from clobbering each
# other. This script just bootstraps the instances, launches, streams, and
# waits.
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
    [int]$HeartbeatSeconds = 5
)

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
    $job = Start-Job -Name "analysis-worker-$i" -ScriptBlock {
        param($ScriptPath, $ParamsTable)
        & $ScriptPath @ParamsTable
    } -ArgumentList $WorkerScript, $workerParams

    $jobEntries += [pscustomobject]@{
        Index     = $i
        Model     = $Model
        Job       = $job
        LastState = $job.State
        Drained   = $false
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
            }
            $entry.LastState = $entry.Job.State
        }

        if ($entry.Job.State -ne "Running") { $entry.Drained = $true }
    }
}

$etaScript = Join-Path $PSScriptRoot "queue_eta.ps1"
$lastEtaAt = Get-Date

while (@($jobEntries | Where-Object { $_.Job.State -eq "Running" }).Count -gt 0) {
    Drain-JobOutput -Entries $jobEntries

    if (-not $DryRun -and (Test-Path -LiteralPath $ManifestPath) -and
        ((Get-Date) - $lastEtaAt).TotalSeconds -ge $EtaEverySeconds) {
        Write-Host ""
        & $etaScript -ManifestPath $ManifestPath -Workers $workerCount
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
    Write-Host "  Worker $($entry.Index + 1) ($($entry.Model)): $state"
    if ($state -eq "Failed") {
        $anyFailed = $true
        Write-Host "    $($entry.Job.ChildJobs[0].JobStateInfo.Reason)" -ForegroundColor Red
    }
    Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
}

if (-not $DryRun -and (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host ""
    & (Join-Path $PSScriptRoot "queue_eta.ps1") -ManifestPath $ManifestPath -Workers $workerCount
}

if ($anyFailed) { exit 1 }
