## Why

Adding `narrative_writer` as a tenth pipeline stage (the previous change) required touching the stage roster in two independently-maintained files (`$StageAgents` in `run_analysis_pipeline.ps1`, `$AgentNames` in `generate_analysis_queue.ps1`), renumbering four hardcoded `$StageAgents[N]` index references by hand, and hand-writing a one-off reset script to backfill the new stage across 1576 already-completed files. That backfill script hit a real bug along the way: two of the three independent places that build an "empty agent usage" template (`Get-AgentSummary`, and the ad-hoc fallback this session added to `Set-AgentTiming`) were missing `prompt_tokens`/`completion_tokens` relative to the schema and the one correct copy (`Get-EmptyAgentUsage`) - a drift that had existed silently until this session's reprocessing run actually exercised it and crashed. Every one of these was a purely mechanical, easy-to-get-wrong step that added a new agent to an already-working chain; none of it required understanding what the new agent does. Adding the eleventh stage (or the twelfth) should not require the same archaeology.

## What Changes

- Introduce a single source of truth for the stage roster - one file both `run_analysis_pipeline.ps1` and `generate_analysis_queue.ps1` load, instead of two hand-synchronized array literals.
- Replace the pipeline runner's per-stage hand-copied blocks (each hardcoding its own `$StageAgents[N]` index, its own resume gate, its own `Invoke-Stage`/`Save-Intermediate`/write-output calls) with one data-driven stage table and a single generic execution loop that walks it. Stage identity comes from the stage's own name, never a numeric position, so inserting a stage no longer requires renumbering anything after it.
- Consolidate the three independent "empty per-agent token_usage record" template builders (`Get-AgentSummary`, `Get-EmptyAgentUsage`, and `Set-AgentTiming`'s defensive fallback) into one canonical function, used everywhere a fresh agent record is needed, so the schema's seven required fields can't silently drift out of sync in only some of the copies again.
- Add a supported backfill script (or a flag on an existing one) that, given a newly-added stage's name, rewinds every already-completed file's `last_completed_stage`/`status` to just before that stage and zeroes its run-total counters - the exact operation this session performed by hand for `narrative_writer`, now a tested, repeatable tool instead of ad-hoc JSON surgery.

Explicitly out of scope: changing what any existing stage does, its prompt, its inputs, or its position in the chain. This is purely about the mechanics of *adding* a stage, not the stages themselves.

## Capabilities

### New Capabilities
- `pipeline-stage-registry`: the single source of truth for the stage roster, the generic per-stage execution mechanism, the canonical agent-usage template, and the backfill tool - the cross-cutting mechanism that makes adding a stage a one-place, low-risk change.

### Modified Capabilities
- `sequential-pipeline-execution`: the runner's stage chain is now driven from the shared registry via a generic execution loop rather than hand-copied per-stage blocks with hardcoded array indices; stage identity and resume gating are name-based, not position-based.
- `analysis-state-persistence`: per-agent `token_usage` records are always built from the one canonical template (all seven schema-required fields), and a documented backfill path exists for propagating a newly-added stage across already-completed state files.

## Impact

- `scripts/run_analysis_pipeline.ps1`: replace `$StageAgents` literal and the nine/ten hand-written per-stage blocks with a load of the shared registry and one generic execution loop; replace `Set-AgentTiming`'s inline fallback template with a call to the canonical builder.
- `scripts/generate_analysis_queue.ps1`: replace `$AgentNames` literal with a load of the shared registry; replace `Get-AgentSummary`'s and `Get-EmptyAgentUsage`'s separate template logic with calls to the canonical builder.
- New file: the shared stage registry (exact name/location decided in design).
- New file (or new flag on an existing script): the backfill tool.
- `openspec/specs/legacy-source-analysis-agents`, `sequential-pipeline-execution`: updated to describe stages as registry entries rather than a literal fixed array, without changing the actual chain order or any stage's behavior.
- No web-viewer changes.
- No change to already-completed files' data - this only changes how the scripts are organized and how a *future* stage addition is carried out.
