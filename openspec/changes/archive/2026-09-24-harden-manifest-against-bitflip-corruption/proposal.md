## Why

`Repair-StrayNonAsciiCharacters` (this session's earlier self-heal fix) only catches corruption that inserts a non-ASCII character. A fifth incident showed that's not the only shape this takes: a manifest entry's closing quote (`"`, 0x22) was replaced by the digit `2` (0x32) — a plain ASCII character, invisible to that scanner. Checking the bit-level difference on both this and the very first confirmed incident (space 0x20 → the stray `U+1020` character) found something concrete: **both are exactly single-bit differences** from the correct value (`0x22 ^ 0x32 = 0x10`; `0x20 ^ 0x1020 = 0x1000`, both powers of two). That's not a pattern software content-scanning produces — it's the textbook signature of a hardware memory or storage reliability issue (failing RAM, a marginal SSD/controller). The existing Defender exclusion and write-verify-retry hardening didn't stop it, consistent with corruption happening to bytes already at rest, not during this pipeline's own writes.

This doesn't fix the underlying hardware risk (out of this project's reach — the user should separately run memory/disk diagnostics). What it can do is widen the pipeline's ability to *recover* from this specific, now well-characterized corruption signature without manual intervention each time, the same way `self-heal-manifest-reads` already does for the non-ASCII-insertion case.

## What Changes

- Add a second-tier repair attempt to the same read paths `self-heal-manifest-reads` already covers (`Read-Manifest`, `queue_eta.ps1`, `backfill_new_stage.ps1`): when the non-ASCII scan finds nothing (or its own repair doesn't parse), and a JSON parse failure occurred, use the failure's own reported line/position as a starting hint, search a small bounded window of nearby characters, and for each, try substituting the **16 single-bit-flip variants** of that character (one per bit of its UTF-16 code unit) — accepting the first substitution that makes the *entire* document parse successfully.
- Bound the total work tightly (a small window, a capped number of full-document re-parse attempts, tried in a sensible priority order) so this stays a fast recovery path even against a multi-megabyte manifest, not a slow brute-force search — exact window size and attempt budget are implementation-time tuning decisions, to be validated against this session's five real incidents (backup copies of all of them still exist under `.analysis-state/queue/manifest.json.pre-repair-backup-*`, usable as real test fixtures rather than only synthetic ones).
- Falls through to today's existing retry/throw behavior if nothing in the budget succeeds — same conservative posture as the existing non-ASCII repair: never accept a guess that doesn't actually parse.

Explicitly out of scope: diagnosing or fixing the underlying hardware cause (a message to the user, not a code change), and applying this same bit-flip-aware repair to `architecture_spec_writer`'s own output repair chain (a different, LLM-output-specific set of failure classes already handled by its own dedicated repair functions — this proposal is scoped to `manifest.json` reads specifically).

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `analysis-state-persistence`: extends the "Manifest is the live, mutable index" auto-repair requirement (added by `self-heal-manifest-reads`) to also attempt a bit-flip-aware single-character correction when the existing non-ASCII repair doesn't apply or doesn't succeed.

## Impact

- `scripts/run_analysis_pipeline.ps1`, `scripts/queue_eta.ps1`, `scripts/backfill_new_stage.ps1`: extend each script's existing repair-attempt block (added by `self-heal-manifest-reads`) with this second tier.
- No manifest format change. No effect on already-completed files.
- Recommend, separately from this code change: the user run Windows Memory Diagnostic (`mdsched.exe`) and check SSD/NVMe SMART health — the actual, most likely fix for the root cause, which this change cannot address in software.
