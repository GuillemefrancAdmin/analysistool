# Verifies the tier-2 manifest repair (Repair-SingleBitFlipCharacter) against
# real evidence rather than synthetic cases alone:
#
#   1. Replays every surviving real pre-repair manifest backup
#      (.analysis-state\queue\manifest.json.pre-repair-backup-*) through the
#      readers' own two-tier sequence (stray non-ASCII scan, then the
#      single-bit-flip search) and through the new tier on its own, and checks
#      the recovered document actually parses and still contains its files.
#   2. Times the worst case: a corruption the tier *cannot* fix (a two-bit flip)
#      is fed in to confirm the search gives up within its bound instead of
#      inventing a repair -- and that the attempt cap (not the clock) is what
#      keeps that fast.
#   3. Confirms healthy content is never touched: every healthy snapshot parses
#      on the first attempt (so the repair path is never reached for it), and
#      the tier refuses to alter already-parsing text even when called directly
#      with a parse-error message that points inside it.
#   4. Runs one real reader (queue_eta.ps1, which accepts -ManifestPath) end to
#      end against a copy of a real corrupted manifest, to check the wiring --
#      not just the helpers -- recovers and carries on.
#
# Read-only with respect to pipeline state: makes no pipeline-state decisions,
# blocks nothing, and the only thing it writes is a temporary *copy* of a
# fixture (under the temp directory, deleted again when done) -- never the live
# manifest or anything else under .analysis-state.
#
# When to use: after any change to the manifest read-repair tiers, or after a
# new manifest-corruption incident, to re-confirm recovery, the worst-case
# bound, and that healthy content is never altered.
#
# Usage:
#   .\verify_manifest_repair.ps1
#   .\verify_manifest_repair.ps1 -FixturePaths a,b -HealthyPaths c
#   .\verify_manifest_repair.ps1 -HealthyJsonSampleSize 0     # live manifest only

param(
    [string[]]$FixturePaths = @(),
    [string[]]$HealthyPaths = @(),
    [int]$HealthyJsonSampleSize = 200,
    [int]$WindowCharacters = 64,
    [int]$MaxAttempts = 200,
    [int]$MaxElapsedMilliseconds = 5000
)

# Relaunch under PowerShell 7 -- that is what every reader of manifest.json
# relaunches into, and tier 2's fast validator (System.Text.Json) plus the
# line/position-bearing parse errors it relies on both only exist there. See
# pipeline_common.ps1 for the forwarding details.
. (Join-Path $PSScriptRoot "pipeline_common.ps1")
Restart-UnderPowerShell7 -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -Required -MissingPwshMessage "pwsh.exe (PowerShell 7) not found -- this verification needs the same engine the manifest readers relaunch into."

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$QueueDir = Join-Path $Root ".analysis-state\queue"
$ManifestPath = Join-Path $QueueDir "manifest.json"

# The real thing, not a copy of it.
. (Join-Path $PSScriptRoot "manifest_repair.ps1")

$failures = New-Object System.Collections.Generic.List[string]

function Report-Check {
    param([bool]$Passed, [string]$Description)
    if ($Passed) {
        Write-Host ("  PASS  {0}" -f $Description) -ForegroundColor Green
    }
    else {
        Write-Host ("  FAIL  {0}" -f $Description) -ForegroundColor Red
        $failures.Add($Description)
    }
}

# The failure message the readers feed to tier 2, or "" if the text parses.
function Get-ManifestParseFailure {
    param([string]$Text)
    try {
        $null = $Text | ConvertFrom-Json
        return ""
    }
    catch { return $_.Exception.Message }
}

if ($FixturePaths.Count -eq 0) {
    $FixturePaths = @(Get-ChildItem -LiteralPath $QueueDir -Filter "manifest.json.pre-repair-backup-*" -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name | ForEach-Object { $_.FullName })
}
if ($HealthyPaths.Count -eq 0) {
    $healthy = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $ManifestPath) { $healthy.Add($ManifestPath) }
    # A manifest snapshot is the closest thing to the real input, but only one
    # healthy full manifest exists on this machine, so also sample the states
    # tree: thousands of small, genuinely-healthy JSON documents are what makes
    # "the tier never alters healthy content" an actual sample rather than a
    # single observation.
    if ($HealthyJsonSampleSize -gt 0) {
        $statesRoot = Join-Path $Root ".analysis-state\states"
        if (Test-Path -LiteralPath $statesRoot) {
            $sample = @(Get-ChildItem -LiteralPath $statesRoot -Recurse -Filter "*.state.json" -File -ErrorAction SilentlyContinue | Select-Object -First $HealthyJsonSampleSize)
            foreach ($file in $sample) { $healthy.Add($file.FullName) }
        }
    }
    $HealthyPaths = $healthy.ToArray()
}

Write-Host ("--- Manifest repair verification ({0}) ---" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
Write-Host ("Engine: {0} {1}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Host ("Tier 2 defaults: window {0} chars, {1} attempts, {2} ms elapsed cap" -f $WindowCharacters, $MaxAttempts, $MaxElapsedMilliseconds)

# ---------------------------------------------------------------------------
# 1. Real incident fixtures
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("1. Real incident backups: {0} found (task 4.1)" -f $FixturePaths.Count) -ForegroundColor Cyan
if ($FixturePaths.Count -eq 0) {
    Write-Host "  (none on disk -- nothing to replay)" -ForegroundColor Yellow
}
$firstFixtureError = ""
foreach ($path in $FixturePaths) {
    Write-Host ("  {0}" -f (Split-Path -Leaf $path)) -ForegroundColor Yellow
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $rawError = Get-ManifestParseFailure -Text $raw
    if (-not $firstFixtureError) { $firstFixtureError = $rawError }
    $summary = if ($rawError.Length -gt 150) { $rawError.Substring(0, 150) + "..." } else { $rawError }
    Report-Check ($rawError -ne "") ("corrupted as expected ({0})" -f $summary)

    $readerSw = [System.Diagnostics.Stopwatch]::StartNew()
    $repairedText = $null
    $tierUsed = ""
    $strayRepair = Repair-StrayNonAsciiCharacters -Text $raw
    if ($strayRepair) {
        try { $null = $strayRepair | ConvertFrom-Json; $repairedText = $strayRepair; $tierUsed = "tier 1 (stray non-ASCII)" }
        catch { }
    }
    if (-not $repairedText) {
        $bitFlip = Repair-SingleBitFlipCharacter -Text $raw -ParseErrorMessage $rawError -WindowCharacters $WindowCharacters -MaxAttempts $MaxAttempts -MaxElapsedMilliseconds $MaxElapsedMilliseconds
        if ($bitFlip) { $repairedText = $bitFlip.Text; $tierUsed = "tier 2 (single-bit-flip)" }
    }
    $readerSw.Stop()
    Report-Check ([bool]$repairedText) ("recovered by the readers' own sequence (tier 1 first): {0}, {1} ms end to end" -f $tierUsed, $readerSw.ElapsedMilliseconds)

    if ($repairedText) {
        Report-Check ((Get-ManifestParseFailure -Text $repairedText) -eq "") "recovered text parses under ConvertFrom-Json"
        $parsed = $repairedText | ConvertFrom-Json
        Report-Check (@($parsed.files).Count -gt 0) ("recovered document still carries its files ({0} entries)" -f @($parsed.files).Count)
    }

    # The new tier on its own, bypassing tier 1: the non-ASCII incident is also
    # a single-bit flip (0x1020 -> 0x0020), so tier 2 must find that one too.
    $bitFlipOnly = Repair-SingleBitFlipCharacter -Text $raw -ParseErrorMessage $rawError -WindowCharacters $WindowCharacters -MaxAttempts $MaxAttempts -MaxElapsedMilliseconds $MaxElapsedMilliseconds
    Report-Check ([bool]$bitFlipOnly) "tier 2 alone also recovers it"
    if ($bitFlipOnly) {
        $xor = $bitFlipOnly.OriginalCodePoint -bxor $bitFlipOnly.CorrectedCodePoint
        Report-Check (($xor -gt 0) -and (($xor -band ($xor - 1)) -eq 0)) ("the fix really is a single bit flip (0x{0:X4} -> 0x{1:X4}, XOR 0x{2:X4})" -f $bitFlipOnly.OriginalCodePoint, $bitFlipOnly.CorrectedCodePoint, $xor)
        Report-Check ($bitFlipOnly.Attempts -le $MaxAttempts) ("within the attempt budget ({0} of {1} candidate reparses)" -f $bitFlipOnly.Attempts, $MaxAttempts)
        Report-Check ($bitFlipOnly.ElapsedMilliseconds -le $MaxElapsedMilliseconds) ("within the elapsed cap ({0} of {1} ms)" -f $bitFlipOnly.ElapsedMilliseconds, $MaxElapsedMilliseconds)
        Report-Check ($bitFlipOnly.Text -eq $repairedText) "both tiers recover identical text"
        Write-Host ("        offset {0}, {1} chars from the reported location, bit {2}, corrected char '{3}' (0x{4:X4})" -f $bitFlipOnly.Position, $bitFlipOnly.Distance, $bitFlipOnly.BitIndex, $bitFlipOnly.CorrectedChar, $bitFlipOnly.CorrectedCodePoint) -ForegroundColor Gray
    }
}

# ---------------------------------------------------------------------------
# 2. Worst case: a corruption this tier cannot fix
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "2. Worst case, against the live manifest (task 4.2)" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host ("  (no live manifest at {0} -- skipping)" -f $ManifestPath) -ForegroundColor Yellow
}
else {
    $live = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8

    # Three quotes, each with two bits flipped: no single-character, single-bit
    # substitution can make that document parse again, so this is the case that
    # has to exhaust the search budget and fall through to the callers'
    # retry/throw rather than be "repaired".
    $damaged = $live.ToCharArray()
    $damagedAt = New-Object System.Collections.Generic.List[int]
    $cursor = [int]($live.Length / 4)
    while ($damagedAt.Count -lt 3) {
        $idx = $live.IndexOf([char]34, $cursor)
        if ($idx -lt 0) { break }
        $damagedAt.Add($idx)
        $cursor = $idx + 100000
    }
    foreach ($idx in $damagedAt) { $damaged[$idx] = [char]([int]$damaged[$idx] -bxor 0x11) }
    $worstText = [string]::new($damaged)
    $worstError = Get-ManifestParseFailure -Text $worstText
    Report-Check (($damagedAt.Count -eq 3) -and ($worstError -ne "")) "damaged 3 characters with two bits each, and the parse now fails"

    $worstSw = [System.Diagnostics.Stopwatch]::StartNew()
    $worstResult = Repair-SingleBitFlipCharacter -Text $worstText -ParseErrorMessage $worstError -WindowCharacters $WindowCharacters -MaxAttempts $MaxAttempts -MaxElapsedMilliseconds $MaxElapsedMilliseconds
    $worstSw.Stop()
    Report-Check ($null -eq $worstResult) "no repair is invented for a corruption this tier cannot fix (returns null, so the readers fall through)"
    Report-Check ($worstSw.ElapsedMilliseconds -lt ($MaxElapsedMilliseconds + 3000)) ("worst case (window searched, nothing found) stayed bounded end to end: {0} ms against the live {1:N1} MB manifest (elapsed cap {2} ms, {3}-attempt cap)" -f $worstSw.ElapsedMilliseconds, ($live.Length / 1MB), $MaxElapsedMilliseconds, $MaxAttempts)

    # The same input with a tiny attempt cap: if the clock were what bounded the
    # search, this would take just as long as the run above did.
    $cappedSw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Repair-SingleBitFlipCharacter -Text $worstText -ParseErrorMessage $worstError -WindowCharacters $WindowCharacters -MaxAttempts 5 -MaxElapsedMilliseconds 600000
    $cappedSw.Stop()
    Report-Check ($cappedSw.ElapsedMilliseconds -lt ($worstSw.ElapsedMilliseconds / 2)) ("the attempt cap is what bounds it: 5 attempts took {0} ms, {1} attempts took {2} ms" -f $cappedSw.ElapsedMilliseconds, $MaxAttempts, $worstSw.ElapsedMilliseconds)

    # Known, accepted limit (design.md's Risks): the acceptance test is "the whole
    # document parses", so a corruption that is NOT a single-bit flip can still be
    # accepted if some single-bit neighbour of some nearby character happens to
    # parse -- observed here as a quote restored one character to the left, which
    # re-opens the property name the damage broke (it parses, but renames that
    # key). Reported rather than asserted against; what IS asserted is the safety
    # invariant that anything returned parses.
    $twoBit = $live.ToCharArray()
    $twoBitAt = $live.IndexOf([char]34, [int]($live.Length / 2))
    $twoBit[$twoBitAt] = [char]([int]$twoBit[$twoBitAt] -bxor 0x11)
    $twoBitText = [string]::new($twoBit)
    $twoBitError = Get-ManifestParseFailure -Text $twoBitText
    $twoBitResult = Repair-SingleBitFlipCharacter -Text $twoBitText -ParseErrorMessage $twoBitError -WindowCharacters $WindowCharacters -MaxAttempts $MaxAttempts -MaxElapsedMilliseconds $MaxElapsedMilliseconds
    if ($twoBitResult) {
        Report-Check ((Get-ManifestParseFailure -Text $twoBitResult.Text) -eq "") "a two-bit flip (not this tier's failure class) is only accepted if the result parses"
        Write-Host ("        note: accepted a parseable candidate {0} chars from the damage even though that damage was not a single-bit flip -- by design, and logged by the callers as '{1}' 0x{2:X4} -> '{3}' 0x{4:X4}" -f $twoBitResult.Distance, $twoBitResult.OriginalChar, $twoBitResult.OriginalCodePoint, $twoBitResult.CorrectedChar, $twoBitResult.CorrectedCodePoint) -ForegroundColor DarkYellow
    }
    else {
        Write-Host "        note: no parseable candidate for the two-bit flip either (falls through)" -ForegroundColor DarkYellow
    }
}

# ---------------------------------------------------------------------------
# 3. Healthy snapshots: nothing to repair, and nothing touched
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("3. Healthy JSON snapshots: {0} to check (task 4.3)" -f $HealthyPaths.Count) -ForegroundColor Cyan
if ($HealthyPaths.Count -eq 0) {
    Write-Host "  (no healthy snapshots found -- nothing to check)" -ForegroundColor Yellow
}
$healthyParsedFirstTry = 0
$probeLocationValid = 0
$guardBlocked = 0
$tier1Touched = 0
foreach ($path in $HealthyPaths) {
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ((Get-ManifestParseFailure -Text $text) -eq "") { $healthyParsedFirstTry++ }
    else { Write-Host ("        not actually healthy: {0}" -f $path) -ForegroundColor Yellow }

    if (Repair-StrayNonAsciiCharacters -Text $text) { $tier1Touched++ }

    # Probe tier 2 directly with a parse-error message whose reported location is
    # genuinely inside this document, so the search really would run (and could
    # "fix" a bit flip inside a string value, which leaves the document valid) if
    # the "never alter already-parsing text" guard weren't there. The live
    # manifest gets a real incident's message; everything else gets a synthetic
    # one whose line 2 always exists.
    $probeMessage = if (($path -eq $ManifestPath) -and $firstFixtureError) {
        $firstFixtureError
    }
    else {
        "Conversion from JSON failed with error: synthetic probe. Path 'x', line 2, position 1."
    }
    if ((Get-OffsetForLinePosition -Text $text -Line 2 -Position 1) -ge 0) { $probeLocationValid++ }
    if ($null -eq (Repair-SingleBitFlipCharacter -Text $text -ParseErrorMessage $probeMessage -WindowCharacters $WindowCharacters -MaxAttempts $MaxAttempts -MaxElapsedMilliseconds $MaxElapsedMilliseconds)) { $guardBlocked++ }
}
if ($HealthyPaths.Count -gt 0) {
    Report-Check ($healthyParsedFirstTry -eq $HealthyPaths.Count) ("every snapshot parses on its first attempt, so the repair path is never reached for it ({0} of {1})" -f $healthyParsedFirstTry, $HealthyPaths.Count)
    Report-Check ($probeLocationValid -eq $HealthyPaths.Count) ("the probe's reported location was valid for every snapshot, so a bad location is not what stopped the search ({0} of {1})" -f $probeLocationValid, $HealthyPaths.Count)
    Report-Check ($guardBlocked -eq $HealthyPaths.Count) ("the tier refused to alter already-parsing content even when called directly ({0} of {1})" -f $guardBlocked, $HealthyPaths.Count)
    Report-Check ($tier1Touched -eq 0) ("tier 1 found nothing suspicious in healthy content ({0} of {1} untouched)" -f ($HealthyPaths.Count - $tier1Touched), $HealthyPaths.Count)
}

# ---------------------------------------------------------------------------
# 4. A real reader, recovering end to end
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "4. Reader wiring, end to end (task 3.3)" -ForegroundColor Cyan
$queueEta = Join-Path $PSScriptRoot "queue_eta.ps1"
# Only tier 2 can fix an ASCII-to-ASCII substitution, so pick a fixture whose
# tier-1 scan finds nothing to repair: that is the one that exercises the new
# wiring rather than the tier that already existed.
$tier2Fixture = ""
foreach ($path in $FixturePaths) {
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $stray = Repair-StrayNonAsciiCharacters -Text $text
    $strayParses = $false
    if ($stray) {
        try { $null = $stray | ConvertFrom-Json; $strayParses = $true }
        catch { }
    }
    if (-not ($stray -and $strayParses)) { $tier2Fixture = $path; break }
}
if (-not $tier2Fixture) {
    Write-Host "  (no fixture needs tier 2, or none is on disk -- skipping the reader run)" -ForegroundColor Yellow
}
else {
    # queue_eta.ps1 accepts -ManifestPath and writes nothing, so a temp copy is
    # enough; the live manifest is never touched.
    Write-Host ("  feeding {0} to queue_eta.ps1 as a temp copy" -f (Split-Path -Leaf $tier2Fixture)) -ForegroundColor Yellow
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-manifest-repair-" + $PID)
    $copy = Join-Path $workDir "manifest.json"
    $pwshExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    try {
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Copy-Item -LiteralPath $tier2Fixture -Destination $copy -Force
        $readerOutput = (& $pwshExe -NoProfile -File $queueEta -ManifestPath $copy 2>&1 | Out-String)
        $readerExit = $LASTEXITCODE
        Report-Check ($readerExit -eq 0) ("the reader exited 0 against a corrupted manifest (was {0})" -f $readerExit)
        Report-Check ($readerOutput -like "*single-bit-flip substitution in manifest.json at offset*") "the reader's own catch path logged the tier-2 repair"
        Report-Check (($readerOutput -like "*Analysis queue progress*") -and ($readerOutput -like "*Completed*")) "the reader then reported the queue normally off the repaired content"
    }
    finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures.Count -eq 0) {
    Write-Host ("All checks passed ({0} incident fixture(s), {1} healthy snapshot(s))." -f $FixturePaths.Count, $HealthyPaths.Count) -ForegroundColor Green
}
else {
    Write-Host ("{0} check(s) FAILED:" -f $failures.Count) -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host ("  - {0}" -f $failure) -ForegroundColor Red }
    exit 1
}



