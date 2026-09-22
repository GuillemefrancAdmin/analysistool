## Why

The pipeline's final stage, `architecture_spec_writer`, is asked to do two things in one call: compress six prior stages' findings into ~30 terse JSON fields, and write a complete, verbose Markdown narrative (`markdown_report`) explaining the file's purpose. On the small local model this pipeline runs against, the narrative consistently loses that budget fight — `markdown_report` comes back empty far more often than not (confirmed across multiple completed files in `.analysis-state/outputs/`), even though the web-viewer already has a ready, currently-unused rendering path for a standalone per-file narrative. Splitting the narrative into its own dedicated stage, reading the same raw findings rather than the already-compressed JSON, removes that budget contention entirely.

## What Changes

- Add a tenth pipeline stage, `narrative_writer`, running alongside `diagram_designer_context_visualizer` (after `test_validation_analyst`, before `architecture_spec_writer`).
- `narrative_writer` consumes the same six raw stage findings `diagram_designer_context_visualizer` already receives (business domain, structural, business logic, security, performance, test validation) — not the compressed final JSON — and produces prose explaining the file's *purpose*: why it exists and what business role it fills, grounded in (but not restating) the structural entry-point list.
- `narrative_writer`'s output is saved as a standalone `<file>.md` sibling output artifact (matching the already-documented-but-until-now-optional convention in `analysis-state-persistence`), not embedded as an escaped JSON string.
- **BREAKING**: `architecture_spec_writer` drops the `markdown_report` field and its instruction from its system prompt and from `templates/source-code-analysis-schema.json`; that responsibility moves entirely to `narrative_writer`.
- Manifest and state-file `output_references` gain the new `.md` reference for every file `narrative_writer` completes, using the same mechanism already used for `diagram.mmd`.
- `token_usage.agents` gains an eleventh entry (`narrative_writer`), alongside the nine analysis stages and `file_queue_orchestrator_agent`.
- No web-viewer changes: `outputs.js` already resolves a `.md` output reference to `outputs.markdown`, and `routes/file.js` already renders it under a "Narrative" section via `renderMarkdown()`. This change only needs to be verified against a real completed file, not built.

Explicitly out of scope: a future per-procedure (rather than per-file) narrative pass. `source_ast_structural_mapper` already enumerates every entry point by name, which a later change could iterate over — noted here as a natural follow-up, not part of this change's tasks.

## Capabilities

### New Capabilities
(none — this extends the existing fixed agent chain rather than introducing a new capability area)

### Modified Capabilities
- `legacy-source-analysis-agents`: the fixed chain grows from nine to ten agent stages; `narrative_writer` is documented as a new agent role (inputs, responsibilities, owned output); `architecture-spec-writer`'s owned-schema-sections requirement drops `markdown_report`.
- `sequential-pipeline-execution`: the runner processes ten stages in fixed order (not nine); `narrative_writer` and `diagram_designer_context_visualizer` both receive the same six-stage input independently, in parallel with each other, ahead of `architecture_spec_writer`.
- `analysis-state-persistence`: the per-file output folder's `<file>.md` artifact is now the narrative_writer's regularly-produced output (no longer just an "if applicable" possibility tied to the final stage); `token_usage.agents` entries required per state-file update grow from ten agent names to eleven.
- `queue-eta-reporting`: ETA proration is based on ten stages remaining, not nine.

## Impact

- `scripts/run_analysis_pipeline.ps1`: add `narrative_writer` to `$StageAgents`, add its system prompt, add its invocation/save-intermediate call parallel to the diagram stage, remove `markdown_report` from `$ArchitectureSpecSystemPrompt` and JSON parsing/validation, add its `.md` output write and `output_references`/manifest wiring.
- `scripts/run_analysis_pipeline_parallel.ps1`: same stage-list and token-usage-shape assumptions likely need the same update (needs verification during implementation).
- `templates/source-code-analysis-schema.json`: remove `markdown_report` from `module` schema... (from top-level report schema — confirm exact key path during implementation).
- `skills/narrative-writer/SKILL.md`: new file, documenting the new agent per the "one subdirectory per agent name" discoverability requirement.
- `web-viewer/`: no code changes; add a manual verification task that `.md` output renders correctly once produced by a real pipeline run.
- Existing completed files in `.analysis-state/outputs/` are unaffected retroactively (no backfill) — only files processed after this change produce a `.md` narrative.
