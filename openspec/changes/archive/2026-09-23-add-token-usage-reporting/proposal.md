## Why

`queue_eta.ps1` already reads every completed/in-progress file's `token_usage.agents.<stage>.{prompt_tokens,completion_tokens,total_tokens}` to drive nothing at all today — that data sits in the manifest unused by the reporter, which only ever looks at `elapsed_seconds`. There's no visibility into how many tokens a run has actually consumed, which stages are token-heavy vs. cheap, or how token cost compares across stages the same way the reporter already compares *time* cost per stage. This matters more now than before this session: `fix-architecture-spec-synthesis` just re-queued all 1,578 completed files for a synthesis-only re-run, and knowing the token footprint of that (and future) runs — not just the time footprint — is directly useful for capacity planning and for spotting anomalies (e.g. a stage whose completion-token count balloons would be a strong, early, free signal of a prompt regression like the one that change just fixed).

## What Changes

- `queue_eta.ps1` reports total tokens consumed across completed files (prompt/completion/combined breakdown), alongside the existing completed/remaining file counts.
- Per-stage token statistics — average tokens/file and total tokens consumed so far per stage — computed with the exact same per-stage-averaging approach already used for `elapsed_seconds` (mixing only real samples for that specific stage, not blended full-chain totals), printed alongside the existing per-stage seconds line.
- Per-stage average throughput (tokens/second), derived from the same samples already being averaged, added as a lightweight extra column rather than a new section.
- Projected total tokens for the remaining queue, mirroring the existing time-based ETA proration logic (summing each remaining file's still-to-run stages' average tokens, not a blended per-file average) — the token-side counterpart to the existing "Estimated remaining time" line.
- Per-model token breakdown, shown only when more than one distinct `model_name` appears across the samples (avoids a misleading blended number in the common single-model case, while staying accurate for a corpus with mixed-model history).

No changes to what data is recorded — every field this reads (`prompt_tokens`, `completion_tokens`, `total_tokens`, `model_name`) is already being written by `run_analysis_pipeline.ps1`'s existing `Set-AgentTiming`. This is a read-only reporting addition to `queue_eta.ps1`, not a pipeline behavior change.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `queue-eta-reporting`: gains new requirements for token-usage statistics (total, per-stage average/total/throughput, projected remaining, per-model breakdown), alongside its existing time-based ETA requirements.

## Impact

- `scripts/queue_eta.ps1`: add token aggregation alongside the existing `$stageAvgSeconds` computation loop, and additional `Write-Host` report lines. No new parameters needed — reuses the manifest already being read.
- No impact on `run_analysis_pipeline.ps1`, `run_analysis_pipeline_parallel.ps1`, or any other script — this only reads already-recorded data.
