## Why

`manifest.json` has now corrupted the same way four separate times in one session: a single stray non-ASCII character (always the same `U+1020` codepoint) appears in raw JSON structural whitespace, immediately before a property name — never inside a string value. Every occurrence broke `ConvertFrom-Json` for the *entire* manifest, which cascades badly: every worker's `Read-Manifest` call fails identically, `run_analysis_pipeline_parallel.ps1`'s crash-recovery relaunches workers that immediately fail the same way, they exhaust their restart budget and give up, and `queue_eta.ps1`'s own read fails too — the whole run stops, mid-progress, needing a manual repair-and-restart each time.

Existing defenses didn't prevent this: a Windows Defender exclusion was added for the folder, and `Write-Utf8NoBom` was hardened to read back and retry its own writes if they don't match what was written. The corruption kept recurring anyway, which is itself informative — since the write-verify-retry would catch corruption happening *during* our own write, whatever's doing this is most likely touching the file *after* a successfully-verified write completes, between one process's write and the next read. The exact external cause is still unconfirmed.

Given the failure signature is now well-characterized across four real incidents (always exactly one non-ASCII character, always in structural whitespace, manifest.json's own content is always plain ASCII so any non-ASCII character in it is unambiguously corruption, never legitimate data), the pipeline can recognize and repair this specific pattern automatically instead of crashing every time it recurs.

## What Changes

- Add `Repair-StrayNonAsciiCharacters`: scans text for a small number of characters outside the normal ASCII range, and if found (and only if found in a small, conservative quantity — not a wholesale rewrite of a differently-broken file), replaces them with spaces and returns the repaired text, without asserting it will parse.
- `Read-Manifest` (`run_analysis_pipeline.ps1`), `queue_eta.ps1`'s manifest read, and `backfill_new_stage.ps1`'s manifest read all try this repair once on a JSON conversion failure, before falling back to their existing retry/throw behavior. The repair is only accepted if the repaired text actually parses; a differently-shaped or larger-scale corruption still falls through to today's behavior (retry, then throw) rather than being silently guessed at.
- The repair is in-memory only for the read that triggered it — no separate persist-the-repair step. The next successful `Save-Manifest` call naturally heals the on-disk copy too, since it re-reads via `Read-Manifest` (which will have already repaired its own copy) before writing.
- A repair event is logged (`[Read-Manifest] Auto-repaired...` / `[queue_eta] Auto-repaired...`) so a recurrence is visible in the run log rather than silently invisible.

Explicitly out of scope: identifying the actual external cause of the corruption (a Windows Search indexing interaction, a backup/sync agent, or something else — still unconfirmed). This change makes the symptom survivable; it doesn't diagnose the root cause.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `analysis-state-persistence`: the "Manifest is the live, mutable index" safety net gains an additional layer — reads now auto-recover from a specific, well-characterized single-character corruption pattern instead of failing outright, on top of the existing write-safety/locking mechanisms.

## Impact

- `scripts/run_analysis_pipeline.ps1`: `Repair-StrayNonAsciiCharacters` added; `Read-Manifest`'s generic-exception branch tries it before retrying.
- `scripts/queue_eta.ps1`: same function duplicated (matching this project's existing convention of small helpers duplicated across standalone scripts rather than a shared module) and wired into its own read loop.
- `scripts/backfill_new_stage.ps1`: same pattern, inline (this script's manifest read isn't in a retry loop the way the other two are, so the repair attempt is a single try/catch around the one read).
- No schema, manifest-format, or pipeline-behavior changes — this only affects what happens on an otherwise-fatal read failure.
- Already implemented and validated: unit-style end-to-end test (inject the exact corruption pattern into a scratch copy of the real manifest, confirm it's broken, run `queue_eta.ps1` against it, confirm it logs the auto-repair and produces a correct report) passed. Also exercised for real: this session's 4th actual corruption incident was manually repaired before this change landed; the change itself is written up now so a 5th incident (if it recurs) is handled automatically.
