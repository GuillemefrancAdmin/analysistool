# Starts the local web viewer for browsing and searching analysis outputs
# under .analysis-state\outputs\ (see web-viewer/). Read-only: it does not
# trigger, control, or modify pipeline runs -- use run_analysis_pipeline.ps1
# / run_analysis_pipeline_parallel.ps1 / stop_analysis_pipeline.ps1 for that.
#
# Requires Node.js. On first run, installs the viewer's npm dependencies.
#
# Usage:
#   .\run_output_viewer.ps1                      # binds 127.0.0.1:5173
#   .\run_output_viewer.ps1 -Port 8080
#   .\run_output_viewer.ps1 -Host 0.0.0.0         # explicit opt-in to network exposure -- no auth is provided, only do this on a trusted network

param(
    [int]$Port = 5173,
    [string]$BindHost = "127.0.0.1"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ViewerDir = Join-Path $RepoRoot "web-viewer"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "Node.js is required to run the output viewer but was not found on PATH. Install Node.js and try again." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path (Join-Path $ViewerDir "node_modules"))) {
    Write-Host "Installing web viewer dependencies (first run only)..." -ForegroundColor Yellow
    Push-Location $ViewerDir
    try {
        npm install
    }
    finally {
        Pop-Location
    }
}

Write-Host "Starting analysis output viewer for $RepoRoot ..." -ForegroundColor Green
node (Join-Path $ViewerDir "server.js") --root $RepoRoot --port $Port --host $BindHost
