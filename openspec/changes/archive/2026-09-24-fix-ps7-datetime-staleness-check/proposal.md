## Why

`Request-NextFile`'s stale-`in_progress`-file reclaim logic — the mechanism that lets a file abandoned by a crashed worker get picked back up by whichever worker is next free, instead of sitting stuck forever waiting for that exact dead worker — silently stopped working once these scripts started running under PowerShell 7 (this session's own earlier fix, for the manifest-size/`ConvertFrom-Json` reliability problem).

Root cause: PowerShell 7's `ConvertFrom-Json` auto-converts an ISO-8601 `"...Z"`-suffixed string into an actual `[datetime]` object (with `Kind=Utc`) — Windows PowerShell 5.1 does not do this, and leaves it as a plain string. The staleness check's `[datetime]::Parse($_.last_updated)` was written assuming `.last_updated` is always a string. Handed an already-`[datetime]` value instead, `Parse()` (which only accepts a string) forces PowerShell to implicitly call `.ToString()` on it first — using the default, timezone-less format, which silently drops the `Kind=Utc` marker — then re-parses that string as `Kind=Unspecified`. The subsequent `.ToUniversalTime()` then treats it as *local* time and shifts it by the machine's UTC offset (4 hours here), making a genuinely stale file's `last_updated` look like it's still recent — or even in the future — so it's never reclaimed.

Confirmed as the actual, live cause of a real incident this session: two files stuck `in_progress` for 3+ hours (`last_updated` correctly showing as stale on manual inspection) were reported by both workers as "nothing to process" on every restart, because the buggy comparison computed a *negative* elapsed time for them.

## What Changes

- `Request-NextFile`'s staleness check now checks `-is [datetime]` first and uses `.ToUniversalTime()` directly on the already-correctly-typed value in that case, falling back to `[datetime]::Parse(...)` only when the value is genuinely still a string (Windows PowerShell 5.1, or any future context where `ConvertFrom-Json` doesn't auto-convert).
- Audited every other place in `run_analysis_pipeline.ps1` that touches `started_at`/`ended_at`/`last_updated` values for the same failure class (an implicit `[datetime]::Parse()` on an already-`[datetime]` value) — none found; every other site either writes a fresh string, does a straight property copy, or does a simple existence/truthy check, none of which trigger this failure mode.
- Corrects an unrelated but directly-adjacent spec inaccuracy discovered while writing this up: `sequential-pipeline-execution`'s "Multi-worker queue partitioning" requirement describes a hash-based static partition scheme (`relative-path hash modulo WorkerCount`) that no longer exists in the code — `-WorkerIndex`/`-WorkerCount` are documented in the script itself as "purely cosmetic/identifying now... workers no longer partition the queue by these." Left uncorrected, that stale requirement would directly contradict the new stale-reclaim requirement this change adds right next to it.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `sequential-pipeline-execution`: "Multi-worker queue partitioning" rewritten to describe the actual current mechanism (dynamic per-file atomic claiming via `Request-NextFile`, `-WorkerIndex`/`-WorkerCount` now cosmetic only); gains a new requirement for stale-`in_progress` reclaim correctness across both PowerShell editions.

## Impact

- `scripts/run_analysis_pipeline.ps1`: `Request-NextFile`'s staleness check, one isolated fix.
- No manifest format change, no effect on already-completed files. Already validated: reproduced the exact bug with a direct test (confirmed `[datetime]::Parse()` on a PS7-auto-converted value produces a negative elapsed time), then confirmed the fix against the real, currently-affected manifest — both previously-stuck files are now correctly identified as claimable.
