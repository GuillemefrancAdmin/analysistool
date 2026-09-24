# Shared repair helpers for readers of .analysis-state\queue\manifest.json.
# Dot-sourced by run_analysis_pipeline.ps1 (Read-Manifest), queue_eta.ps1 and
# backfill_new_stage.ps1 so all three apply exactly the same repairs -- the
# tier-1 scan below used to be a hand-copied inline block in each of them
# (which is how backfill's copy drifted into throwing where the others
# returned $null).
#
# When to use: never run directly -- it has no entry point of its own. It is
# dot-sourced by the three manifest readers above; a change here is what to
# reach for when a manifest corruption pattern needs handling, and the only
# place that has to change.
#
# Both tiers are conservative in the same way: a repair is only ever returned
# as *text*, the caller still parses it itself, and content that doesn't
# actually parse is never accepted -- the caller falls through to its existing
# retry/throw behavior instead.
#
# Tier 1: Repair-StrayNonAsciiCharacters -- a handful of non-ASCII characters
# (the confirmed shape of the first four incidents: a stray U+1020 landing in
# structural whitespace). manifest.json's own content is always plain ASCII, so
# any non-ASCII character in it is reliably corruption.
#
# Tier 2: Repair-SingleBitFlipCharacter -- one character replaced by another,
# *plausible* character (the fifth incident: a closing quote 0x22 replaced by
# the digit 0x32). Nothing about a "2" is suspicious to a content scanner, so
# tier 1 structurally cannot see this class. Every confirmed incident is
# exactly one bit different from the correct value (0x22 ^ 0x32 = 0x10;
# 0x20 ^ 0x1020 = 0x1000) -- the signature of a hardware memory/storage fault,
# not of anything this pipeline's own code writes. So tier 2 searches for "a
# position where flipping exactly one bit makes the whole document parse"
# rather than "a character that looks wrong", which is the only tractable form
# of this search for an ASCII-to-ASCII substitution.

# Detects and repairs the single-stray-non-ASCII-character corruption pattern
# confirmed on manifest.json across four separate real incidents in one
# session -- always exactly one character outside the normal ASCII range,
# sitting in raw JSON structural whitespace (never inside a string value).
# manifest.json's own content (paths, statuses, timestamps, token counts) is
# always plain ASCII, so any non-ASCII character appearing in it at all is
# reliably corruption, never legitimate data -- unlike, say, narrative/report
# text elsewhere in this project, which can genuinely contain accented
# characters. Conservative: only acts when a small number of suspicious
# characters are found (a handful, not a wholesale rewrite of a
# differently-broken file) and only returns the repair if it actually parses
# -- the caller falls through to its own retry/throw otherwise.
function Repair-StrayNonAsciiCharacters {
    param([string]$Text, [int]$MaxSuspiciousChars = 5)
    $chars = $Text.ToCharArray()
    $suspiciousIndexes = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $chars.Count; $i++) {
        $cp = [int]$chars[$i]
        if ($cp -lt 9 -or ($cp -gt 13 -and $cp -lt 32) -or $cp -gt 126) {
            $suspiciousIndexes.Add($i)
            if ($suspiciousIndexes.Count -gt $MaxSuspiciousChars) { return $null }
        }
    }
    if ($suspiciousIndexes.Count -eq 0) { return $null }
    foreach ($idx in $suspiciousIndexes) { $chars[$idx] = ' ' }
    # [string]::new(char[]) rather than -join: identical result, but -join walks
    # 7.3M chars one object at a time (measured 2.3s) where the constructor
    # copies the buffer (measured 6ms) -- and this runs on a real incident.
    return [string]::new($chars)
}

# Extracts the 1-based line and position a ConvertFrom-Json failure reports.
# Both observed message shapes end in "... Path 'x', line N, position P." (the
# "Conversion from JSON failed with error: ..." form and the "After parsing a
# value an unexpected character was encountered: ..." form). A message with no
# location in it (e.g. Windows PowerShell 5.1's "Invalid JSON primitive: .")
# returns $null, which makes tier 2 a no-op -- the caller then falls through to
# its existing retry/throw behavior rather than searching an arbitrary region.
function Get-JsonErrorLinePosition {
    param([string]$Message)
    if (-not $Message) { return $null }
    $match = [regex]::Match($Message, "line\s+(\d+),\s*position\s+(\d+)")
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Line     = [int]$match.Groups[1].Value
        Position = [int]$match.Groups[2].Value
    }
}

# Maps that line/position back to a 0-based character offset in $Text, which is
# what the search window is centered on. The reported position is *not* always
# on the corrupted character -- a parser only notices once it has consumed a few
# more tokens, and on all three surviving real backups the corruption sits
# exactly 10 characters earlier -- which is why the search uses a window rather
# than only the reported position. Returns -1 when the line number is outside
# the document (tier 2 is then a no-op).
#
# Scans with string.IndexOf(char, int) in a loop rather than indexing $Text one
# character at a time: measured 260ms vs 1.7s for a 7.3MB manifest whose failure
# is reported at line ~65000 of ~250000. The two-argument IndexOf must be given
# a [char]: handing it the string "`n" binds to the culture-sensitive *string*
# overload instead, measured ~4ms per call -- i.e. minutes over that many lines.
function Get-OffsetForLinePosition {
    param([string]$Text, [int]$Line, [int]$Position)
    if (-not $Text) { return -1 }
    if ($Line -lt 1) { return -1 }
    $offset = 0
    $remaining = $Line - 1
    while ($remaining -gt 0) {
        $index = $Text.IndexOf([char]10, $offset)
        if ($index -lt 0) { return -1 }
        $offset = $index + 1
        $remaining--
    }
    $offset += ($Position - 1)
    if ($offset -lt 0) { $offset = 0 }
    if ($offset -ge $Text.Length) { $offset = $Text.Length - 1 }
    return $offset
}

# The candidate substitutions for one character: its 16 single-bit-flip
# variants (one per bit of its UTF-16 code unit), ordered by how likely each is
# to be the true value in a JSON document:
#   0 - a common JSON syntax character (the quote, comma, colon, braces,
#       brackets, space) -- the class every confirmed incident turned out to be
#   1 - any other printable ASCII character
#   2 - everything else (control characters, non-ASCII)
# and within a tier in bit order, so the whole candidate sequence is
# deterministic. A variant landing on a lone UTF-16 surrogate is dropped (not a
# valid character on its own). 16 candidates per position is what keeps the
# total search bounded; "try a plausible substitution alphabet instead" would
# be open-ended, and is not what the evidence points at.
function Get-BitFlipCharacterVariants {
    param([char]$Character)
    $code = [int]$Character
    $variants = New-Object System.Collections.Generic.List[object]
    for ($bit = 0; $bit -lt 16; $bit++) {
        $variant = $code -bxor (1 -shl $bit)
        if ($variant -ge 0xD800 -and $variant -le 0xDFFF) { continue }
        $priority = 2
        if ($variant -ge 32 -and $variant -le 126) { $priority = 1 }
        if (@("`"", ",", ":", "{", "}", "[", "]", " ") -ccontains ([char]$variant)) { $priority = 0 }
        $variants.Add([pscustomobject]@{
            Character = [char]$variant
            CodePoint = $variant
            BitIndex  = $bit
            Priority  = $priority
        })
    }
    return $variants
}


# Tier 2. Given manifest text that just failed to parse, and the message from
# that failure, searches for a single-character, single-bit-flip substitution
# that makes the *entire* document parse. Returns $null when nothing within the
# budget works, so the caller falls through to its own retry/throw behavior.
#
# On success returns the repaired text plus the forensics of what was changed
# (offset, the two characters and their code points, which bit, how far the fix
# was from the reported location, how many reparses it took, how long). The
# callers log those: they are the only signal this project has about the
# underlying hardware fault (e.g. whether incidents cluster at particular file
# offsets, which would point at a specific bad memory region).
#
# The defaults are the implementation-time tuning decisions left open by
# design.md, validated against the surviving real incident backups
# (.analysis-state\queue\manifest.json.pre-repair-backup-*, one per incident --
# a byte-identical duplicate of the second was removed in a later cleanup):
#   ...20260923T204340  0x1020 -> 0x0020 (bit 12)  found at attempt 16
#   ...20260924T064435  0x0032 -> 0x0022 (bit 4)   found at attempt 15
# both exactly 10 characters before the offset the failing parse reports
# (see Get-OffsetForLinePosition), hence the 64-character window: ~6x margin on
# the one real distance ever observed, in both directions. 200 attempts is
# comfortably above the 15-16 needed; a full-window search that finds nothing
# takes ~2.9s against the live 7.3MB manifest, because the fast validator below
# costs ~14ms per full-document reparse.
function Repair-SingleBitFlipCharacter {
    param(
        [string]$Text,
        [string]$ParseErrorMessage,
        [int]$WindowCharacters = 64,
        [int]$MaxAttempts = 200,
        [int]$MaxElapsedMilliseconds = 5000
    )
    if (-not $Text) { return $null }

    # Every candidate has to be confirmed by parsing the whole document again --
    # there is no cheaper reliable "is this JSON valid" check for an arbitrary
    # document. System.Text.Json.JsonDocument (present on pwsh / PowerShell 7,
    # which is what these scripts relaunch into) can validate straight out of a
    # mutable char buffer, so a candidate costs one in-place character write plus
    # a parse: measured 8-14ms per attempt against a 7.3MB manifest, versus
    # ~500ms for ConvertFrom-Json. Windows PowerShell 5.1 has neither
    # JsonDocument nor ReadOnlyMemory, so there the same search falls back to
    # ConvertFrom-Json -- which is exactly why MaxElapsedMilliseconds, not only
    # the attempt count, bounds the work.
    #
    # This validator is a filter, never the acceptance test: the text it
    # approves is returned to the caller, and the caller still parses it with
    # ConvertFrom-Json before using it. A stricter or merely different parser
    # here can therefore never turn into an accepted repair -- at worst it costs
    # one candidate.
    $fastValidator = 'System.Text.Json.JsonDocument' -as [type]
    $validatorOptions = $null
    $memory = $null

    if ($fastValidator) {
        $validatorOptions = [System.Text.Json.JsonDocumentOptions]::new()
        # Only this is relaxed: JsonDocument rejects nesting deeper than 64 by
        # default where ConvertFrom-Json has no such limit, and silently
        # disabling this whole tier on a deeply-nested document would be worse
        # than useless.
        $validatorOptions.MaxDepth = 256
    }

    $chars = $Text.ToCharArray()
    if ($fastValidator) { $memory = [System.ReadOnlyMemory[char]]::new($chars) }

    # Defensive: never "repair" text that already parses. The callers only reach
    # this after a failed parse, but a bit flip *inside* a string value leaves
    # the document valid -- it would be accepted as a "repair" and silently
    # replace real data. Checking up front makes that structurally impossible
    # (and costs one parse, ~25ms, on the already-rare failure path).
    $alreadyParses = $true
    try {
        if ($fastValidator) {
            $existing = $fastValidator::Parse($memory, $validatorOptions)
            $existing.Dispose()
        }
        else {
            $null = $Text | ConvertFrom-Json
        }
    }
    catch { $alreadyParses = $false }
    if ($alreadyParses) { return $null }

    $location = Get-JsonErrorLinePosition -Message $ParseErrorMessage
    if (-not $location) { return $null }
    $seed = Get-OffsetForLinePosition -Text $Text -Line $location.Line -Position $location.Position
    if ($seed -lt 0) { return $null }

    # Candidate order: by character tier first (see Get-BitFlipCharacterVariants),
    # then by distance from the reported location within each tier. Every real
    # incident is tier 0 and is found after 15-16 attempts this way, versus
    # 309-317 attempts when the location is the outer loop and all 16 variants of
    # a position are tried before moving to the next one (measured on the same
    # fixtures) -- this ordering is what makes a budget this small sufficient.
    $positions = New-Object System.Collections.Generic.List[int]
    $lowest = [Math]::Max(0, $seed - $WindowCharacters)
    $highest = [Math]::Min($chars.Length - 1, $seed + $WindowCharacters)
    for ($distance = 0; $distance -le $WindowCharacters; $distance++) {
        foreach ($position in @(($seed - $distance), ($seed + $distance))) {
            if ($position -lt $lowest -or $position -gt $highest) { continue }
            if ($positions.Contains($position)) { continue }
            $positions.Add($position)
        }
    }

    $candidatesByTier = @(
        (New-Object System.Collections.Generic.List[object]),
        (New-Object System.Collections.Generic.List[object]),
        (New-Object System.Collections.Generic.List[object])
    )
    foreach ($position in $positions) {
        foreach ($variant in (Get-BitFlipCharacterVariants -Character $chars[$position])) {
            $candidatesByTier[$variant.Priority].Add([pscustomobject]@{
                Position = $position
                Variant  = $variant
            })
        }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    foreach ($tier in @(0, 1, 2)) {
        foreach ($candidate in $candidatesByTier[$tier]) {
            if ($attempts -ge $MaxAttempts) { return $null }
            if ($stopwatch.ElapsedMilliseconds -ge $MaxElapsedMilliseconds) { return $null }

            $position = $candidate.Position
            $replacement = $candidate.Variant.Character
            $original = $chars[$position]
            $attempts++

            $parsed = $false
            $repairedText = $null
            $chars[$position] = $replacement
            try {
                if ($fastValidator) {
                    $document = $fastValidator::Parse($memory, $validatorOptions)
                    $document.Dispose()
                }
                else {
                    $candidateText = [string]::new($chars)
                    $null = $candidateText | ConvertFrom-Json
                }
                $repairedText = if ($fastValidator) { [string]::new($chars) } else { $candidateText }
                $parsed = $true
            }
            catch { $parsed = $false }
            # Restore before looking at the result, so the candidate sequence
            # never depends on what was tried before it.
            $chars[$position] = $original

            if ($parsed) {
                $stopwatch.Stop()
                return [pscustomobject]@{
                    Text                = $repairedText
                    Position            = $position
                    OriginalChar        = $original
                    CorrectedChar       = $replacement
                    OriginalCodePoint   = [int]$original
                    CorrectedCodePoint  = [int]$replacement
                    BitIndex            = $candidate.Variant.BitIndex
                    Distance            = [Math]::Abs($position - $seed)
                    Attempts            = $attempts
                    ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
                }
            }
        }
    }
    return $null
}
