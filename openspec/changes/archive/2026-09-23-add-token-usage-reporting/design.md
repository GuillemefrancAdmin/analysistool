## Context

`queue_eta.ps1` already has exactly the iteration pattern this needs: for each stage name, it loops every manifest file, collects `token_usage.agents.<stage>.elapsed_seconds` samples wherever present (any status, not just `completed`), and averages them per stage (`$stageAvgSeconds`). The same per-file entries also carry `prompt_tokens`, `completion_tokens`, `total_tokens`, and `model_name` — read today, used by nothing.

`Get-RemainingSecondsEstimate` prorates a remaining file's estimate by summing, from its `last_completed_stage` onward, each remaining stage's average — not a blended full-chain average times a fraction. That distinction exists specifically because a backfilled file (see `backfill_new_stage.ps1`) only reruns a tail of the chain, so its `run_total_elapsed_seconds` covers a handful of stages, not all ten; blending that against fresh full-chain completions would understate remaining work. The same reasoning applies to `run_total_tokens`: `backfill_new_stage.ps1` zeroes it at rewind time, so for a backfilled file it reflects only the most recent completion pass, not the file's full processing history — summing the per-stage `total_tokens` entries instead (which backfill explicitly leaves untouched for stages before the rewind point) gives the complete historical total.

## Goals / Non-Goals

**Goals:**
- Reuse the existing per-stage sample-collection loop (extend it, don't duplicate it) to also collect token counts in the same pass over `$manifest.files`.
- Mirror `Get-RemainingSecondsEstimate`'s exact proration logic for a token-side projection, for the same correctness reason it already exists.
- Surface per-model breakdown only when it's not misleading (more than one model actually appears).

**Non-Goals:**
- No new script parameters — this is additive reporting only, using data already being read.
- No cost/dollar figures — this pipeline runs against a local Ollama instance; tokens are the only meaningful unit here.
- No change to what `run_analysis_pipeline.ps1` records — `prompt_tokens`/`completion_tokens`/`total_tokens`/`model_name` are already written by `Set-AgentTiming`.

## Decisions

**Total tokens consumed is computed by summing per-stage `total_tokens` samples, not by summing each file's `run_total_tokens`.** For a file that was never backfilled these are equal; for a backfilled file, `run_total_tokens` only reflects the most recent completion pass (zeroed at rewind time), while summing per-stage entries — which backfill explicitly leaves untouched for stages before the rewind point — captures the file's complete historical token cost. This is the same reasoning `Get-RemainingSecondsEstimate` already applies to time, extended to tokens for consistency.

**Throughput (tokens/second) uses `completion_tokens ÷ elapsed_seconds`, not `total_tokens`.** Prompt/input tokens are processed in a separate, much faster "prefill" phase than generation; blending them into a tokens/sec figure would conflate two different performance characteristics. Computed as sum-of-completion-tokens ÷ sum-of-elapsed-seconds per stage (not an average of per-file ratios), which is the correct aggregate rate and avoids a handful of very-short samples skewing the number.

**Per-model breakdown only prints when more than one distinct `model_name` appears in the samples.** A single-model corpus (the common case) would get a redundant, cluttering one-line "breakdown." Multi-model history (e.g. after switching `-Model`) gets an honest per-model split instead of one misleading blended figure.

**New `Get-RemainingTokensEstimate` function, structurally identical to the existing `Get-RemainingSecondsEstimate`** (same `$startIndex` derivation from `last_completed_stage`, same per-remaining-stage summation with the same average/fallback logic) rather than trying to generalize both into one parameterized function. The two are conceptually parallel but operate on different hashtables computed in the same loop; keeping them as separate, near-identical small functions matches this script's existing style (plain, readable, not over-abstracted) more than a shared generic helper would.

## Risks / Trade-offs

- **[Risk] Widening the existing per-stage collection loop to also touch tokens changes a working, correctness-sensitive function.** → Mitigation: purely additive within the loop body (new accumulator variables alongside the existing `$samples` array), no change to the existing seconds-averaging logic or its output.
- **[Trade-off] Summing per-stage `total_tokens` for the "total consumed" figure can double-count if the same stage's entry gets overwritten mid-count in a live run (a worker updates it between this script's read and its own aggregation).** → Accepted: `queue_eta.ps1` already reads one point-in-time manifest snapshot per invocation (no live re-read mid-computation), so this is a non-issue in practice, same as the existing seconds-based stats already tolerate.

## Migration Plan

None — purely additive to a read-only reporting script. No data migration, no effect on already-completed files, no effect on `run_analysis_pipeline.ps1`.
