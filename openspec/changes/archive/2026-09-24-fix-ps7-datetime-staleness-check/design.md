## Context

`Request-NextFile` claims the next eligible file: first any `queued`/`blocked` file, and if none, any `in_progress` file whose `last_updated` is older than `-StaleSeconds` (default 300). That second branch is what lets a file abandoned by a worker that crashed outright (e.g. a raw `clr.dll` access violation, where nothing in-script gets a chance to mark it blocked) get picked back up by a different, live worker instead of sitting stuck indefinitely.

`last_updated` is written as an ISO-8601 string (`Get-UtcNowStamp`: `"yyyy-MM-ddTHH:mm:ssZ"`) but read back through `ConvertFrom-Json`, whose behavior for such strings differs by PowerShell edition: PS7 auto-detects and converts them to `[datetime]` (`Kind=Utc`); Windows PowerShell 5.1 leaves them as plain strings. This session's earlier fix (`self-heal-manifest-reads` and the PS7-relaunch-guard work before it) made these scripts run under PS7 by default wherever available — which is exactly what exposed this latent edition difference as a live bug.

## Goals / Non-Goals

**Goals:**
- Make the staleness comparison correct under both PowerShell editions, regardless of whether `ConvertFrom-Json` auto-converts the value.
- Confirm no other date-comparison site in the same script has the same latent bug.

**Non-Goals:**
- A general "always treat manifest dates as strings" policy (e.g. forcing `ConvertFrom-Json` to skip its auto-conversion) — narrower, more surgical to fix the one call site that does arithmetic on the value, per this script's established style of small, targeted fixes over blanket policy changes.
- Diagnosing why the two specific real files got stuck `in_progress` in the first place (that trace back to the manifest-corruption crash loop, already a separate, already-addressed problem this session) — this fix is about why they then failed to be *reclaimed*, a distinct bug.

## Decisions

**Type-check first (`-is [datetime]`), rather than trying to coerce or normalize the value before parsing.** The `[datetime]` case is already correctly typed and `Kind`-tagged by `ConvertFrom-Json` itself — the bug was never in that conversion, only in re-parsing its *string representation* afterward. Checking the type and using the value directly when it's already a `[datetime]` avoids the lossy `ToString()`/`Parse()` round-trip entirely, rather than trying to make that round-trip lossless (e.g. by specifying an explicit round-trip format string) — simpler, and removes a whole class of future format-string mismatches.

**Audited rather than assumed clean.** Grepped every `started_at`/`ended_at`/`last_updated`/`[datetime]::Parse` site in the file (`Set-AgentTiming`'s `[datetime]` parameters are fresh in-process `Get-Date` values, never parsed from JSON; the manifest-entry-splice in `Update-ManifestEntry` is a straight property copy, type-agnostic; the `-not $state.started_at` check is a simple existence check, safe for either type). Only the one `Request-NextFile` site does arithmetic requiring a parsed value.

**Corrected the adjacent stale spec text rather than leaving it alongside a contradicting new requirement.** Normally out of scope for a narrow bug-fix change (this session's discipline throughout has been: flag unrelated pre-existing drift, don't fix it inline) — but this specific case is different in kind: the existing "Multi-worker queue partitioning" requirement describes the *same mechanism* this change adds a requirement about, and describes it *incorrectly* (a hash-partition scheme the code comments themselves say no longer exists). Leaving it as-is would mean the spec file contains two directly contradictory descriptions of how workers claim files.

## Risks / Trade-offs

- **[Risk] A future PowerShell version or configuration could change `ConvertFrom-Json`'s auto-conversion behavior again in some other way not covered by `-is [datetime]` vs. string.** → Accepted: this is the same edition-difference class of bug this whole session has repeatedly hit and fixed narrowly each time (encoding, manifest size, now this) rather than trying to preempt every possible future divergence; the `elseif ($_.last_updated)` string-parse fallback still covers any value that isn't already a `[datetime]`.
- **[Trade-off] Correcting the "Multi-worker queue partitioning" requirement here bundles a doc-accuracy fix into a bug-fix change**, slightly outside this change's narrow scope. → Accepted given the direct-contradiction reasoning above; the correction is spec-text only, zero code risk.

## Migration Plan

None — single-function logic fix, no manifest/state format change. Already validated against the real, currently-affected manifest (both previously-stuck files now correctly identified as claimable) before this write-up.
