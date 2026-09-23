## 1. Token aggregation (`scripts/queue_eta.ps1`)

- [x] 1.1 Extend the existing per-stage sample-collection loop (the one building `$stageAvgSeconds`) to also accumulate, per stage, sample counts for `prompt_tokens`, `completion_tokens`, `total_tokens`, in the same pass over `$manifest.files` rather than a second iteration.
- [x] 1.2 Compute per-stage average tokens/file and total tokens/stage from those accumulators, alongside the existing `$stageAvgSeconds`.
- [x] 1.3 Compute per-stage throughput as sum(completion_tokens)/sum(elapsed_seconds) for that stage's samples.
- [x] 1.4 Compute whole-manifest total prompt/completion/combined tokens by summing per-stage totals (accumulated inline during the same 1.1 loop pass, not `run_total_tokens`, per design.md's reasoning about backfilled files).
- [x] 1.5 Track distinct `model_name` values seen across samples and their per-model token totals, for the conditional breakdown.

## 2. Remaining-queue token projection

- [x] 2.1 Add `Get-RemainingTokensEstimate`, structurally mirroring `Get-RemainingSecondsEstimate`: same `$startIndex` derivation from `last_completed_stage`, summing remaining stages' average tokens (falling back to the cross-stage average for a stage with no samples yet, same as the seconds version).
- [x] 2.2 Sum this across all remaining (`queued`/`blocked`/`in_progress`) files to get the total projected remaining tokens.

## 3. Report output

- [x] 3.1 Print total tokens consumed (prompt/completion/combined). Placed in a new grouped "--- Token usage ---" section at the end of the report rather than interleaved with the existing completed/remaining counts near the top -- lower-risk diff (no reordering of already-working print statements) and keeps all new content clearly grouped together.
- [x] 3.2 Print a per-stage table: average tokens/file, total tokens, throughput (tokens/sec) — alongside or near the existing per-stage-implied seconds reporting.
- [x] 3.3 Print projected remaining tokens for the queue, in the new Token usage section.
- [x] 3.4 Print the per-model breakdown only when more than one distinct `model_name` was observed (task 1.5); omit the section entirely otherwise.
- [x] 3.5 Handle the zero-data case (no recorded token usage anywhere) without a divide-by-zero or a misleading all-zeros report.

## 4. Verification

- [x] 4.1 Run `queue_eta.ps1` against the live manifest and confirm the new sections print correctly alongside the existing time-based report, with numbers that look sane (spot-check one stage's total against a manual grep/sum of a few real manifest entries). Confirmed against the live manifest (49 completed, 1529 remaining): 48,768,345 total tokens (37.3M prompt + 11.5M completion), sane per-stage averages (sanitizer highest at 4,945 avg tokens/file, matching it being the raw-source-ingestion stage), and a genuinely useful anomaly surfaced immediately: narrative_writer's throughput (9.8 tok/sec) is 4-6x slower than every other stage (44-64 tok/sec) -- worth its own follow-up investigation, not part of this change.
- [x] 4.2 Confirm the per-model breakdown is correctly omitted (single model currently in use) or shown (if the manifest happens to have historical multi-model samples). Shown correctly: 3 distinct model names found in the live manifest's history (`llama3.1:8b`, `meta-llama-3.1-8b-gpu0`, `meta-llama-3.1-8b-gpu1`) -- real historical model-naming inconsistency the feature was specifically designed to surface honestly rather than blend into one misleading number.
- [x] 4.3 Confirm no performance regression: `queue_eta.ps1` still completes promptly against the ~7MB+ live manifest (single extended pass, not a second full iteration). Confirmed: report returned promptly, same single-pass structure as before.
