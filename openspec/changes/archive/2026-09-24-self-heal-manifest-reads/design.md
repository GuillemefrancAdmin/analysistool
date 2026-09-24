## Context

Four real corruption incidents this session, all with the identical signature: a single `U+1020` character, always in raw JSON structural whitespace (between a value's trailing comma/brace and the next property's opening quote), never inside a string value. `manifest.json`'s own content — file paths, statuses, ISO timestamps, integer/float token and timing counts — is always plain ASCII by construction (unlike, say, narrative/report text elsewhere in this project's outputs, which legitimately contains accented characters). That makes "any non-ASCII character present at all" a reliable, low-false-positive corruption signal specifically for this file, empirically confirmed across all four incidents (each scan found exactly one suspicious character, zero false positives on the surrounding tens of megabytes of legitimate content).

`Write-Utf8NoBom` already reads back and retries its own write if the result doesn't match what was written (added earlier this session, after the first two incidents). The corruption recurred a third and fourth time regardless, which rules out (or at least strongly deprioritizes) the corruption happening *during* this codebase's own write path — that would have been caught. The likely window is between a verified-good write and the next read, from some other process — still unconfirmed which one.

`Read-Manifest`, `queue_eta.ps1`, and `backfill_new_stage.ps1` each read `manifest.json` independently; a parse failure in any of them today means retry-then-throw, which for `Read-Manifest` specifically cascades into worker crash loops (`run_analysis_pipeline_parallel.ps1`'s relaunch logic retries the same broken read, fails identically, exhausts its restart budget, gives up).

## Goals / Non-Goals

**Goals:**
- Recognize the specific, now well-characterized corruption pattern and repair it transparently, so a recurrence doesn't stop a run or require manual intervention.
- Stay conservative — never silently accept a repair for a differently-shaped or larger-scale corruption; fall through to existing retry/throw behavior for anything that doesn't match the known pattern.
- Make a repair event visible in the log, not silently invisible.

**Non-Goals:**
- Diagnosing the external root cause. This is a survivability fix for the symptom, not a fix for whatever is causing it.
- A general-purpose JSON repair capability — this targets exactly the one confirmed pattern (stray non-ASCII characters in structural whitespace), the same scoping discipline already applied to `Repair-JsonEscapes`/`Repair-JsonTruncation`/`Repair-UnescapedEmbeddedQuotes` for `architecture_spec_writer`'s own output.
- Persisting the repair back to disk as its own explicit step — see Decisions below for why this isn't needed.

## Decisions

**The repair is in-memory only; no explicit persist-back-to-disk step.** `Save-Manifest`'s own read-modify-write cycle calls `Read-Manifest` internally before writing (to splice in one entry's update against the current on-disk state). Since `Read-Manifest` now repairs in-memory on any call, the very next successful `Save-Manifest` — from any worker, happening frequently, once per stage completion — will naturally read the corrupted file, silently repair its own in-memory copy, and write back a fully-corrected manifest as a side effect of ordinary operation. Adding a separate mutex-protected "persist the repair immediately" step would duplicate `Save-Manifest`'s own locking/atomic-write logic for no real benefit, since the natural healing already happens within, at most, one stage-completion's worth of time on an active run.

**Conservative threshold: repair is only attempted for a small number of suspicious characters (5 or fewer).** A file with many non-ASCII characters is more likely a different, larger-scale problem (or a legitimate assumption about "always ASCII" being wrong in some new way) than four more instances of this exact bug arriving at once — silently guessing at a bigger problem risks producing a manifest that "parses" but is wrong in ways nobody asked for. Falling through to the existing throw-after-retries behavior in that case keeps the failure loud and visible rather than papering over something unfamiliar.

**Same detection logic duplicated in three places (`Read-Manifest`, `queue_eta.ps1`, `backfill_new_stage.ps1`), not factored into a shared module.** Matches this project's existing, deliberate convention (`Write-Utf8NoBom` is similarly duplicated between `run_analysis_pipeline.ps1` and `backfill_new_stage.ps1`) — these are independent, directly-runnable standalone scripts, and a shared module would be a bigger structural change than this fix warrants.

## Risks / Trade-offs

- **[Risk] If the real corruption source ever produces a *different* stray character or a slightly different structural position, this exact heuristic might not catch it.** → Accepted: the detection (any character outside normal ASCII range, anywhere in the raw text) is already broader than "exactly `U+1020` in exactly this structural position" — it would catch a different stray character too, as long as it's still non-ASCII and still low in count. A genuinely different failure mode (e.g. truncation, a torn write) is already handled by the existing IOException-retry path, unaffected by this change.
- **[Trade-off] This treats a symptom without knowing the cause, which could in principle let a worse underlying problem go unnoticed if it only ever manifests this same, now-silently-repaired way.** → Mitigated by the logged repair event — a recurrence is visible in the run log (searchable, countable) even though it no longer stops the run, so a rising frequency would still be noticeable rather than truly invisible.

## Migration Plan

None — purely additive resilience on the read path. No manifest format change, no effect on already-completed files. Already validated end-to-end (inject the real corruption pattern into a scratch copy, confirm `queue_eta.ps1` auto-repairs and reports correctly) before this write-up.
