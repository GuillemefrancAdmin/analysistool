# Stops any currently-running run_analysis_pipeline.ps1 process(es) --
# single-worker or, in parallel mode, one per worker -- without touching any
# state/output/checkpoint files or the manifest. Safe to run any time you
# just want to stop an in-progress run (e.g. before editing the pipeline
# script itself, or before manually reviewing/resuming the queue).
#
# Each running instance registers a lock file under .analysis-state\locks\
# for as long as it's alive (see run_analysis_pipeline.ps1); this script
# finds those, verifies the process is actually still running, and stops it.
#
# Usage:
#   .\stop_analysis_pipeline.ps1            # prompts for confirmation
#   .\stop_analysis_pipeline.ps1 -Force     # no prompt

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LocksDir = Join-Path $RepoRoot ".analysis-state\locks"

# The lock file's shape is parsed in one place (see pipeline_common.ps1), so
# this script and reset_analysis_state.ps1 can't drift from what
# run_analysis_pipeline.ps1 actually writes.
. (Join-Path $PSScriptRoot "pipeline_common.ps1")
$locks = Get-AnalysisLocks -LocksDir $LocksDir
$liveLocks = $locks.Live
$staleLockFiles = $locks.StaleFiles
foreach ($f in $staleLockFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

if ($liveLocks.Count -eq 0) {
    Write-Host "No running pipeline process found." -ForegroundColor Green
    exit 0
}

Write-Host "Found $($liveLocks.Count) running pipeline process(es): $(($liveLocks | ForEach-Object { "PID $($_.Pid)" }) -join ', ')" -ForegroundColor Yellow

if (-not $Force) {
    $answer = Read-Host "Type 'yes' to terminate"
    if ($answer -ne "yes") {
        Write-Host "Aborted. Nothing was stopped." -ForegroundColor Yellow
        exit 1
    }
}

foreach ($lock in $liveLocks) {
    Stop-Process -Id $lock.Pid -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $lock.LockFile -Force -ErrorAction SilentlyContinue
    Write-Host "Terminated PID $($lock.Pid)." -ForegroundColor Green
}
