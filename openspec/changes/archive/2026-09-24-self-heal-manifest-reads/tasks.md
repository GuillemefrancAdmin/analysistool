## 1. Repair function

- [x] 1.1 Add `Repair-StrayNonAsciiCharacters` to `scripts/run_analysis_pipeline.ps1`: scans text for characters with codepoint `<9`, `(>13 and <32)`, or `>126`; returns `$null` if none found or if more than 5 found (too many to confidently guess); otherwise replaces each with a space and returns the repaired text.
- [x] 1.2 Duplicate the same logic into `scripts/queue_eta.ps1` (as its own function) and inline into `scripts/backfill_new_stage.ps1`'s manifest read (matching this project's existing convention for small helpers in independent standalone scripts).

## 2. Wire into read paths

- [x] 2.1 `Read-Manifest` (`run_analysis_pipeline.ps1`): in the generic-exception branch (JSON parse failure, as opposed to the `[System.IO.IOException]` branch which is a separate locked-file retry), attempt the repair once; on success, log `[Read-Manifest] Auto-repaired...` and return the repaired result; on failure, fall through to the existing retry/throw.
- [x] 2.2 `queue_eta.ps1`'s manifest read loop: same pattern, logging `[queue_eta] Auto-repaired...`.
- [x] 2.3 `backfill_new_stage.ps1`'s manifest read: same pattern (single try/catch, not a retry loop, since this script's existing read wasn't one).

## 3. Verification

- [x] 3.1 Syntax-check all three modified scripts under both Windows PowerShell 5.1 and PowerShell 7.
- [x] 3.2 End-to-end test: copy the real (healthy) manifest to a scratch location, inject the exact real corruption pattern (a `U+1020` character into whitespace before a property name, deep in the file), confirm the copy is actually broken (fails to parse), then run `queue_eta.ps1 -ManifestPath <scratch copy>` against it.
- [x] 3.3 Confirm the run logs the auto-repair message and produces a correct, complete report (not a crash, not a silently-wrong report) — confirmed: logged `[queue_eta] Auto-repaired a stray non-ASCII character in manifest.json and re-parsed successfully.` followed by the full, correct progress/token-usage report.
- [x] 3.4 Applied to the real, live manifest during this session's actual 4th corruption incident: manually repaired (same technique, pre-dating this change landing) to unblock the run immediately; this change ensures a 5th incident, if it recurs, is handled automatically instead of needing the same manual intervention.
