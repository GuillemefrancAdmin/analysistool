## 1. Agent definition

- [x] 1.1 Create `skills/narrative-writer/SKILL.md`, documenting its role, mission, inputs (the same six findings `diagram-designer-context-visualizer` receives), responsibilities, and its owned output artifact (`<file>.md`), per the "Agent definitions are discoverable" requirement in `legacy-source-analysis-agents`.

## 2. Pipeline script changes (`scripts/run_analysis_pipeline.ps1`)

- [x] 2.1 Add `"narrative_writer"` to `$StageAgents` as the new index 8, between `"diagram_designer_context_visualizer"` (stays index 7) and `"architecture_spec_writer"` (shifts to index 9).
- [x] 2.2 Add `$NarrativeWriterSystemPrompt`, positioned alongside the other stage prompts, instructing the model to explain the file's purpose (why it exists, what business role it fills) using the business domain and business logic findings as primary source, structural entry points only for grounding — explicitly not a rehash of security/performance/quality findings.
- [x] 2.3 Add the resume-gated invocation block for stage 8, mirroring the diagram stage's `if ($resumeIndex -le 7) { ... }` pattern at `-le 8`: build the same `$userContent` composition already used for the diagram call, call `Invoke-Stage -AgentName $StageAgents[8]`, `Save-Intermediate`, update `last_completed_stage`/`Save-State`, and `Write-Utf8NoBom` the result to `<file>.md` in `$outDir` (no JSON parsing needed — plain text like the diagram).
- [x] 2.4 Add the corresponding resume-rehydration line alongside the existing `if ($resumeIndex -gt 7) { $diagram = Get-SavedStage $StageAgents[7] }` (around line 1128), so a run resuming after stage 8 has already completed doesn't need to re-derive anything narrative-writer produced.
- [x] 2.5 Renumber every remaining `$StageAgents[8]` reference (currently meaning `architecture_spec_writer`) to `$StageAgents[9]` — the `Invoke-Stage` call, `Save-Intermediate` call, and `last_completed_stage` assignment in the final-synthesis block (`run_analysis_pipeline.ps1:1239-1272`). Verify with `grep -n 'StageAgents\[8\]'` returning zero matches afterward.
- [x] 2.6 Add `<file>.md` to `$outputRefs` unconditionally when narrative-writer's write succeeds (mirroring the existing `Test-Path ... diagram.mmd` pattern), independent of whether the later `architecture_spec_writer` JSON parse succeeds or fails.
- [x] 2.7 Remove `markdown_report` entirely from `$ArchitectureSpecSystemPrompt`'s field list and instructions, and remove the `if ($parsed.markdown_report) { ... }` write branch (`run_analysis_pipeline.ps1:1249-1254`) from the final-synthesis parse block.

## 3. Queue generator changes (`scripts/generate_analysis_queue.ps1`)

- [x] 3.1 Add `"narrative_writer"` to `$AgentNames` in the same relative position (after `"diagram_designer_context_visualizer"`, before `"architecture_spec_writer"`), so newly-discovered files get a `token_usage.agents.narrative_writer` entry in their initial manifest template.
- [x] 3.2 Diff `$StageAgents` (pipeline script) against `$AgentNames` (queue generator) to confirm identical membership and relative order after both edits.

## 4. Schema

- [x] 4.1 Remove the `markdown_report` property (and its description/instruction text) from `templates/source-code-analysis-schema.json`.

## 5. Verification

- [x] 5.1 Run the pipeline against a small number of real files (`-Limit` a handful) and confirm: `narrative_writer` appears in each file's `token_usage.agents`, a non-empty `<file>.md` is written to the output folder, `output_references` includes it, and `architecture_spec_writer`'s JSON no longer has a `markdown_report` key.
- [x] 5.2 Read the generated `<file>.md` narratives and confirm they read as purpose-focused explanations, not a restatement of the other report sections.
- [x] 5.3 Open one of those files in the web-viewer's file detail page and confirm the "Narrative" section renders the `.md` content via the existing (currently-dormant) `outputs.markdown` path — no web-viewer code changes expected; this step is verification only.
- [x] 5.4 Confirm resumability: interrupt a run after stage 7 (diagram) completes but before stage 8 (narrative) does, restart, and confirm it resumes at `narrative_writer` rather than re-running earlier stages or skipping ahead to `architecture_spec_writer`.
