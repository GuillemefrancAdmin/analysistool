# PowerShell port of generate_analysis_queue.py. Discovers legacy source
# files under the documented discovery_scope, builds/refreshes
# .analysis-state/queue/manifest.json, and creates a per-file state record
# under .analysis-state/states/ for any file that doesn't already have one.
#
# Re-running this script is safe: existing state files (and any progress
# recorded in them) are never overwritten, and state filenames are derived
# deterministically from each file's own relative path, so collisions
# between files that share a base name (e.g. README.md in several folders)
# always resolve to the same name on every run.
#
# Usage:
#   .\generate_analysis_queue.ps1

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $Root ".analysis-state"
$QueueDir = Join-Path $StateRoot "queue"
$StatesDir = Join-Path $StateRoot "states"
$CheckpointsDir = Join-Path $StateRoot "checkpoints"
$OutputsDir = Join-Path $StateRoot "outputs"

$SourceExtensions = @(
    ".4gl", ".aid", ".bat", ".cbl", ".cob", ".cobol", ".com", ".cpp",
    ".c", ".dcl", ".h", ".inc", ".osq", ".php", ".ps1", ".qcb", ".rw",
    ".sc", ".scb", ".sh", ".sql", ".txt", ".tpl", ""
)

# Matches MANIFEST.md's documented discovery_scope. Anything outside these
# top-level folders (scripts/, templates/, skills/, .analysis-state/, ...) is
# tooling for the workflow itself, not legacy source to analyze.
$DiscoveryRoots = @(
    "source code",
    "Processus affaires",
    "documentation"
)

$ExcludedDirs = @(
    ".git", ".analysis-state", ".venv", "venv", "__pycache__",
    "node_modules", "dist", "build", "target", ".idea", ".vscode"
)

$SpecialFileNames = @("env.inc", "global.config.php", "dsn.html", "dsnmssql.html")

$AgentNames = @(
    "file_queue_orchestrator_agent",
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

function Get-UtcNowStamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    # Atomic write-then-rename -- see the matching comment in
    # run_analysis_pipeline.ps1's Write-Utf8NoBom for why (torn reads of
    # manifest.json by concurrent readers like queue_eta.ps1).
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp-$PID"
    [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
    if (Test-Path -LiteralPath $Path) {
        # See the matching comment in run_analysis_pipeline.ps1's
        # Write-Utf8NoBom -- File.Replace's 3-arg overload throws on a
        # $null backup-file argument here; a real throwaway path works.
        $backupPath = "$Path.bak-$PID"
        # Retry on transient sharing violations (AV/indexer) -- see the
        # matching comment in run_analysis_pipeline.ps1's Write-Utf8NoBom.
        $maxAttempts = 5
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                [System.IO.File]::Replace($tempPath, $Path, $backupPath)
                break
            }
            catch [System.IO.IOException] {
                if ($attempt -eq $maxAttempts) { throw }
                Start-Sleep -Milliseconds (100 * $attempt)
            }
        }
        Remove-Item -LiteralPath $backupPath -ErrorAction SilentlyContinue
    }
    else {
        [System.IO.File]::Move($tempPath, $Path)
    }
}

function Get-RelativePosixPath {
    param([string]$FullPath, [string]$RootPath)
    $relative = $FullPath.Substring($RootPath.Length).TrimStart('\', '/')
    return $relative -replace '\\', '/'
}

function Test-ExcludedPath {
    param([string]$FullPath)
    $segments = $FullPath -split '[\\/]'
    foreach ($segment in $segments) {
        if ($ExcludedDirs -ccontains $segment) { return $true }
    }
    return $false
}

function Test-CandidateFile {
    param([System.IO.FileInfo]$Item)

    if (Test-ExcludedPath -FullPath $Item.FullName) { return $false }
    if ($Item.Name.StartsWith(".") -and $Item.Name -cne ".analysis-state") { return $false }

    $suffix = $Item.Extension.ToLowerInvariant()
    $name = $Item.Name.ToLowerInvariant()

    if ($SourceExtensions -contains $suffix) { return $true }
    if ($name.EndsWith(".qcb") -or $name.EndsWith(".scb") -or $name.EndsWith(".4gl")) { return $true }
    if ($SpecialFileNames -ccontains $Item.Name) { return $true }
    return $false
}

function Get-CandidateFiles {
    param([string]$RootPath)
    $files = @()
    foreach ($scopeName in $DiscoveryRoots) {
        $scopeRoot = Join-Path $RootPath $scopeName
        if (-not (Test-Path -LiteralPath $scopeRoot -PathType Container)) { continue }
        $scoped = Get-ChildItem -LiteralPath $scopeRoot -Recurse -File |
            Sort-Object FullName |
            Where-Object { Test-CandidateFile -Item $_ }
        $files += $scoped
    }
    return $files
}

function Get-BaseStateName {
    param([System.IO.FileInfo]$Item)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Item.Name)
    $ext = $Item.Extension.TrimStart(".").ToLowerInvariant()
    if ([string]::IsNullOrEmpty($ext)) { $ext = "file" }
    return "$stem.$ext.state.json"
}

function Get-PathHash {
    param([string]$RelativePath)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($RelativePath)
        $hashBytes = $sha1.ComputeHash($bytes)
        $hex = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
        return $hex.Substring(0, 8)
    }
    finally {
        $sha1.Dispose()
    }
}

function Get-StateNameMap {
    param([System.IO.FileInfo[]]$Files, [string]$RootPath)

    # Deterministic, collision-safe state filenames keyed by relative path.
    # Two different files can share a base name (e.g. README.md nested under
    # several folders). Disambiguation must depend only on each file's own
    # relative path, not on scan order or which state files already exist on
    # disk, so re-running this generator never renames or duplicates a
    # file's state record.
    $groups = @{}
    foreach ($file in $Files) {
        $baseName = Get-BaseStateName -Item $file
        if (-not $groups.ContainsKey($baseName)) { $groups[$baseName] = @() }
        $groups[$baseName] += $file
    }

    $result = @{}
    foreach ($baseName in $groups.Keys) {
        $group = $groups[$baseName]
        if ($group.Count -eq 1) {
            $result[$group[0].FullName] = $baseName
            continue
        }
        $stemSuffix = $baseName.Substring(0, $baseName.Length - ".state.json".Length)
        foreach ($file in $group) {
            $relativePath = Get-RelativePosixPath -FullPath $file.FullName -RootPath $RootPath
            $result[$file.FullName] = "$stemSuffix.$(Get-PathHash -RelativePath $relativePath).state.json"
        }
    }
    return $result
}

function Get-EmptyAgentUsage {
    $usage = [ordered]@{}
    foreach ($agentName in $AgentNames) {
        $usage[$agentName] = [ordered]@{
            model_name        = ""
            started_at        = $null
            ended_at          = $null
            elapsed_seconds   = 0
            prompt_tokens     = 0
            completion_tokens = 0
            total_tokens      = 0
        }
    }
    return $usage
}

function Get-ExistingState {
    param([string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        return Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-AgentSummary {
    param($ExistingAgents, [string]$AgentName)
    $existing = $null
    if ($ExistingAgents) { $existing = $ExistingAgents.($AgentName) }
    $summary = [ordered]@{
        model_name      = ""
        started_at      = $null
        ended_at        = $null
        elapsed_seconds = 0
        total_tokens    = 0
    }
    if ($existing) {
        if ($null -ne $existing.model_name) { $summary.model_name = $existing.model_name }
        if ($null -ne $existing.started_at) { $summary.started_at = $existing.started_at }
        if ($null -ne $existing.ended_at) { $summary.ended_at = $existing.ended_at }
        if ($null -ne $existing.elapsed_seconds) { $summary.elapsed_seconds = $existing.elapsed_seconds }
        if ($null -ne $existing.total_tokens) { $summary.total_tokens = $existing.total_tokens }
    }
    return $summary
}

function New-ManifestEntry {
    param([System.IO.FileInfo]$Item, [string]$StateName, [string]$RootPath)

    $relativePath = Get-RelativePosixPath -FullPath $Item.FullName -RootPath $RootPath
    # A completed file's state record is relocated to states/done/ by
    # run_analysis_pipeline.ps1. Check there first so a rescan points back at
    # it instead of treating the file as new and creating a blank duplicate
    # at the old flat location.
    $stateFile = ".analysis-state/states/done/$StateName"
    if (-not (Test-Path -LiteralPath (Join-Path $RootPath ($stateFile -replace '/', '\')))) {
        $stateFile = ".analysis-state/states/$StateName"
    }
    $existingState = Get-ExistingState -StatePath (Join-Path $RootPath ($stateFile -replace '/', '\'))

    $existingAgents = $null
    $existingRunTotalTokens = 0
    $existingRunTotalElapsed = 0
    if ($existingState -and $existingState.token_usage) {
        $existingAgents = $existingState.token_usage.agents
        if ($null -ne $existingState.token_usage.run_total_tokens) {
            $existingRunTotalTokens = $existingState.token_usage.run_total_tokens
        }
        if ($null -ne $existingState.token_usage.run_total_elapsed_seconds) {
            $existingRunTotalElapsed = $existingState.token_usage.run_total_elapsed_seconds
        }
    }

    $agents = [ordered]@{}
    foreach ($agentName in $AgentNames) {
        $agents[$agentName] = Get-AgentSummary -ExistingAgents $existingAgents -AgentName $agentName
    }

    $status = "queued"
    $lastCompletedStage = $null
    $lastUpdated = $null
    if ($existingState) {
        $status = $existingState.status
        $lastCompletedStage = $existingState.last_completed_stage
        $lastUpdated = $existingState.updated_at
    }

    return [ordered]@{
        path                 = $relativePath
        file_name            = $Item.Name
        analysis_type        = "legacy-source-analysis"
        status               = $status
        last_completed_stage = $lastCompletedStage
        last_updated         = $lastUpdated
        state_file           = $stateFile
        token_usage          = [ordered]@{
            run_total_tokens         = $existingRunTotalTokens
            run_total_elapsed_seconds = $existingRunTotalElapsed
            agents                   = $agents
        }
    }
}

function Write-StateFileIfMissing {
    param([string]$RelativePath, [string]$StateFile, [string]$RootPath)

    $statePath = Join-Path $RootPath ($StateFile -replace '/', '\')
    if (Test-Path -LiteralPath $statePath) {
        # Preserve any progress already recorded; a rescan must never reset it.
        return $false
    }
    $parent = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $payload = [ordered]@{
        source_path          = $RelativePath
        analysis_type         = "legacy-source-analysis"
        status                = "queued"
        last_completed_stage  = $null
        started_at            = $null
        updated_at            = Get-UtcNowStamp
        blocker_or_error      = $null
        next_action           = "discover_and_queue_file"
        output_references     = @()
        token_usage           = [ordered]@{
            run_total_tokens          = 0
            run_total_elapsed_seconds = 0
            agents                    = Get-EmptyAgentUsage
        }
    }

    $json = $payload | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $statePath -Content ($json + "`n")
    return $true
}

function Main {
    foreach ($path in @($StateRoot, $QueueDir, $StatesDir, $CheckpointsDir, $OutputsDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    $files = Get-CandidateFiles -RootPath $Root
    $stateNames = Get-StateNameMap -Files $files -RootPath $Root

    $manifestFiles = @()
    $newlyQueued = 0
    foreach ($file in $files) {
        $stateName = $stateNames[$file.FullName]
        $entry = New-ManifestEntry -Item $file -StateName $stateName -RootPath $Root
        $created = Write-StateFileIfMissing -RelativePath $entry.path -StateFile $entry.state_file -RootPath $Root
        if ($created) { $newlyQueued++ }
        $manifestFiles += $entry
    }

    $manifest = [ordered]@{
        run_id          = Get-UtcNowStamp
        status          = "initialized"
        scan_each_turn  = $true
        processing_mode = "one-file-at-a-time"
        files           = $manifestFiles
    }

    $manifestPath = Join-Path $QueueDir "manifest.json"
    $json = $manifest | ConvertTo-Json -Depth 15
    Write-Utf8NoBom -Path $manifestPath -Content ($json + "`n")

    Write-Host "Queued $($manifestFiles.Count) files under $Root"
    Write-Host "Manifest written to $manifestPath"

    $statusCounts = [ordered]@{
        queued      = 0
        in_progress = 0
        blocked     = 0
        completed   = 0
        failed      = 0
    }
    foreach ($entry in $manifestFiles) {
        $key = $entry.status
        if (-not $statusCounts.Contains($key)) { $statusCounts[$key] = 0 }
        $statusCounts[$key]++
    }

    Write-Host ""
    Write-Host "--- Queue stats ---"
    Write-Host "Total tracked files : $($manifestFiles.Count)"
    Write-Host "Newly discovered     : $newlyQueued"
    Write-Host "Already tracked      : $($manifestFiles.Count - $newlyQueued)"
    foreach ($key in $statusCounts.Keys) {
        Write-Host ("  {0,-12} : {1}" -f $key, $statusCounts[$key])
    }
}

Main
