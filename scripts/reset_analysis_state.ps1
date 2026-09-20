# Wipes all generated queue/state/checkpoint/output artefacts under
# .analysis-state so the file-by-file analysis workflow can restart from
# scratch. Leaves the hand-written docs (README.md, MANIFEST.md, the
# states/README.md convention doc) and everything outside .analysis-state
# (skills/, templates/, source code/, etc.) untouched.
#
# Usage:
#   .\reset_analysis_state.ps1                # prompts for confirmation
#   .\reset_analysis_state.ps1 -Force         # no prompt
#   .\reset_analysis_state.ps1 -Regenerate    # also rebuilds the queue afterward
#   .\reset_analysis_state.ps1 -Force -Regenerate

param(
    [switch]$Force,
    [switch]$Regenerate
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $RepoRoot ".analysis-state"
$StatesDir = Join-Path $StateRoot "states"
$CheckpointsDir = Join-Path $StateRoot "checkpoints"
$OutputsDir = Join-Path $StateRoot "outputs"
$ManifestPath = Join-Path $StateRoot "queue\manifest.json"
$LocksDir = Join-Path $StateRoot "locks"

if (-not (Test-Path $StateRoot)) {
    throw "No .analysis-state directory found at $StateRoot"
}

# run_analysis_pipeline.ps1 (single or, in parallel mode, one per worker
# process) registers a lock file for as long as it's running. Deleting the
# state/output files it's actively reading and writing out from under it
# would corrupt its in-flight run, so find and stop any still-live ones
# first. Stale locks (process no longer running) are just cleaned up.
$liveLocks = @()
$staleLockFiles = @()
if (Test-Path $LocksDir) {
    foreach ($lockFile in Get-ChildItem -Path $LocksDir -Filter "*.lock" -File) {
        $info = Get-Content -LiteralPath $lockFile.FullName -Raw | ConvertFrom-Json
        $proc = Get-Process -Id $info.pid -ErrorAction SilentlyContinue
        if ($proc) {
            $liveLocks += [pscustomobject]@{ Pid = $info.pid; WorkerIndex = $info.worker_index; LockFile = $lockFile.FullName }
        }
        else {
            $staleLockFiles += $lockFile.FullName
        }
    }
}
foreach ($f in $staleLockFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

# Per-file state records, but never the convention doc that lives alongside them.
$stateFiles = @()
if (Test-Path $StatesDir) {
    $stateFiles = Get-ChildItem -Path $StatesDir -Recurse -File | Where-Object { $_.Name -ne "README.md" }
}

$checkpointFiles = @()
if (Test-Path $CheckpointsDir) {
    $checkpointFiles = Get-ChildItem -Path $CheckpointsDir -File
}

$outputFiles = @()
if (Test-Path $OutputsDir) {
    $outputFiles = Get-ChildItem -Path $OutputsDir -Recurse -File
}

$hasManifest = Test-Path $ManifestPath

Write-Host "This will permanently delete:" -ForegroundColor Yellow
Write-Host "  - $($stateFiles.Count) file(s) in states\"
Write-Host "  - $($checkpointFiles.Count) file(s) in checkpoints\"
Write-Host "  - $($outputFiles.Count) file(s) in outputs\"
Write-Host "  - queue\manifest.json $(if (-not $hasManifest) { '(not present)' })"
if ($liveLocks.Count -gt 0) {
    Write-Host "  - and TERMINATE $($liveLocks.Count) still-running pipeline process(es): $(($liveLocks | ForEach-Object { "PID $($_.Pid)" }) -join ', ')" -ForegroundColor Yellow
}

if ($stateFiles.Count -eq 0 -and $checkpointFiles.Count -eq 0 -and $outputFiles.Count -eq 0 -and -not $hasManifest -and $liveLocks.Count -eq 0) {
    Write-Host "Nothing to clean; .analysis-state is already empty." -ForegroundColor Green
    exit 0
}

if (-not $Force) {
    $answer = Read-Host "Type 'yes' to continue"
    if ($answer -ne "yes") {
        Write-Host "Aborted. Nothing was deleted." -ForegroundColor Yellow
        exit 1
    }
}

foreach ($lock in $liveLocks) {
    Stop-Process -Id $lock.Pid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lock.LockFile -Force -ErrorAction SilentlyContinue
    Write-Host "Terminated running pipeline process PID $($lock.Pid)." -ForegroundColor Yellow
}

foreach ($file in $stateFiles) { Remove-Item -Path $file.FullName -Force }
foreach ($file in $checkpointFiles) { Remove-Item -Path $file.FullName -Force }
foreach ($file in $outputFiles) { Remove-Item -Path $file.FullName -Force }

# Drop any now-empty subdirectories left under outputs\ or states\ (e.g.
# states\done\), but keep outputs\ and states\ themselves.
foreach ($dir in @($OutputsDir, $StatesDir)) {
    if (Test-Path $dir) {
        Get-ChildItem -Path $dir -Recurse -Directory |
            Sort-Object { $_.FullName.Length } -Descending |
            Where-Object { (Get-ChildItem -Path $_.FullName -Force | Measure-Object).Count -eq 0 } |
            Remove-Item -Force
    }
}

if ($hasManifest) { Remove-Item -Path $ManifestPath -Force }

Write-Host "Cleaned $($stateFiles.Count) state file(s), $($checkpointFiles.Count) checkpoint(s), $($outputFiles.Count) output artefact(s), and the queue manifest." -ForegroundColor Green

if ($Regenerate) {
    $generator = Join-Path $PSScriptRoot "generate_analysis_queue.ps1"
    Write-Host "Regenerating queue via $generator ..." -ForegroundColor Cyan
    & $generator
}
else {
    Write-Host "Queue not regenerated. Run generate_analysis_queue.ps1 (or re-run this script with -Regenerate) when ready to rebuild it." -ForegroundColor Cyan
}
