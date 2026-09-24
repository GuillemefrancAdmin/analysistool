# Rewinds already-"completed" files to just before -NewStageName so the next
# pipeline run re-executes that one stage, reusing every earlier stage's
# saved intermediate rather than reprocessing from scratch. Two distinct
# uses:
#
#   1. Propagating a newly-added stage across files that completed the full
#      chain before that stage existed - the operation add-narrative-writer-
#      agent performed by hand (twice, hitting a BOM bug and a missing-fields
#      bug along the way) when narrative_writer was added. By default, only
#      files with no recorded usage yet for -NewStageName are matched.
#
#   2. Force re-running a stage whose PROMPT/behavior changed after files
#      already completed it once (e.g. fix-architecture-spec-synthesis: the
#      final-synthesis prompt was fixed after 1,578 files had already run it
#      with the old, buggy prompt). Pass -EvenIfAlreadyRun to match every
#      "completed" file regardless of whether -NewStageName already has a
#      recorded result for it - the default match-only-if-never-run
#      condition would otherwise select nothing, since every file already
#      has *a* result for that stage, just a low-quality one.
#
# Either way, this rewinds last_completed_stage (in both the state file and
# the manifest entry) to the stage immediately preceding -NewStageName in
# the shared registry, sets status back to "queued", and zeroes the file's
# run-total counters. Per-agent history for stages before the rewind point -
# including -NewStageName's own now-stale entry under -EvenIfAlreadyRun - is
# left exactly as recorded until that stage actually reruns and overwrites
# its own entry.
#
# Safe to run while other files are still being actively processed: matched
# files are, by definition, already "completed" (a live worker only holds
# "in_progress" files), and the manifest update is done under the same
# cross-process mutex run_analysis_pipeline.ps1's Save-Manifest uses, so it
# can't interleave with a live worker's own manifest write.
#
# When to use: after a stage is added to the roster, or after an existing
# stage's prompt/behavior changes, and you want files that already completed
# the chain to pick that up -- report-only until you pass -Force.
#
# Usage:
#   .\backfill_new_stage.ps1 -NewStageName narrative_writer
#       # report-only: prints how many files would be touched, writes nothing
#   .\backfill_new_stage.ps1 -NewStageName narrative_writer -Force
#       # actually performs the rewind
#   .\backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun
#       # report-only: force-rewind mode, matches every completed file
#   .\backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun -Force
#       # actually re-queues every completed file for that stage alone

param(
    [Parameter(Mandatory = $true)][string]$NewStageName,
    [switch]$Force,
    [switch]$EvenIfAlreadyRun
)

# Relaunch under PowerShell 7 when available: this script reads and rewrites the
# whole manifest, which outgrows Windows PowerShell 5.1's parser. See
# pipeline_common.ps1 for how the parameter forwarding works.
. (Join-Path $PSScriptRoot "pipeline_common.ps1")
Restart-UnderPowerShell7 -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $RepoRoot ".analysis-state"
$ManifestPath = Join-Path $StateRoot "queue\manifest.json"

. (Join-Path $PSScriptRoot "pipeline_stages.ps1")

# The manifest read-repair helpers (the stray-non-ASCII scan and the
# single-bit-flip search) live in one shared file so this script repairs
# manifest.json exactly the way run_analysis_pipeline.ps1's Read-Manifest and
# queue_eta.ps1 do -- it used to carry its own third, subtly different inline
# copy of just the first scan.
. (Join-Path $PSScriptRoot "manifest_repair.ps1")

# Write-Utf8NoBom (the atomic, verified manifest write) comes from
# pipeline_common.ps1, dot-sourced at the top of this script -- this script,
# run_analysis_pipeline.ps1 and generate_analysis_queue.ps1 all write
# manifest.json and used to carry their own copy, one of which had silently
# missed the read-back verification the others gained.

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

    # Auto-repairs both known manifest.json corruption patterns -- see
    # manifest_repair.ps1 for what each tier covers and the real-incident
    # evidence behind it. Same posture as the other two readers: neither repair
    # is used unless it actually re-parses, and if neither applies this throws
    # exactly as it did before either tier existed.
    $manifestRaw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    $manifest = $null
    $manifestParseError = ""
    try {
        $manifest = $manifestRaw | ConvertFrom-Json
    }
    catch {
        $manifestParseError = $_.Exception.Message
        $strayRepair = Repair-StrayNonAsciiCharacters -Text $manifestRaw
        if ($strayRepair) {
            try {
                $manifest = $strayRepair | ConvertFrom-Json
                Write-Host "Auto-repaired a stray non-ASCII character in manifest.json and re-parsed successfully." -ForegroundColor Yellow
            }
            catch { $manifest = $null }
        }
        if (-not $manifest) {
            $bitFlip = Repair-SingleBitFlipCharacter -Text $manifestRaw -ParseErrorMessage $manifestParseError
            if ($bitFlip) {
                try {
                    $manifest = $bitFlip.Text | ConvertFrom-Json
                    Write-Host ("Auto-repaired a single-bit-flip substitution in manifest.json at offset {0} ('{1}' 0x{2:X4} -> '{3}' 0x{4:X4}, bit {5}, {6} chars from the reported location, after {7} candidate reparses) and re-parsed successfully." -f $bitFlip.Position, $bitFlip.OriginalChar, $bitFlip.OriginalCodePoint, $bitFlip.CorrectedChar, $bitFlip.CorrectedCodePoint, $bitFlip.BitIndex, $bitFlip.Distance, $bitFlip.Attempts) -ForegroundColor Yellow
                }
                catch { $manifest = $null }
            }
        }
        if (-not $manifest) { throw }
    }

    $targets = $manifest.files | Where-Object {
        $_.status -eq "completed" -and
        ($EvenIfAlreadyRun -or -not $_.token_usage.agents.($NewStageName) -or -not $_.token_usage.agents.($NewStageName).model_name)
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
