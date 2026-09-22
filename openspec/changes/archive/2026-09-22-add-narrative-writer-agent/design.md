## Context

The nine-stage chain lives in `scripts/run_analysis_pipeline.ps1` as `$StageAgents`, a fixed-order array referenced two ways throughout the file: by name (readable) and by hardcoded numeric index (`$StageAgents[7]`, `$StageAgents[8]`, etc.) for both stage identity and resume/checkpoint gating (`if ($resumeIndex -le 7) { ... }` skips a stage already completed in a prior run). That same agent roster is duplicated, by hand, in a second file — `scripts/generate_analysis_queue.ps1`'s `$AgentNames` — which builds the `token_usage.agents` template every manifest entry starts with when a file is first discovered. `run_analysis_pipeline_parallel.ps1` does *not* duplicate the roster; it just spawns worker processes running `run_analysis_pipeline.ps1` itself, so it needs no changes here.

`architecture_spec_writer` (stage index 8, the last one) currently produces both the final JSON report and, optionally, `markdown_report`, written out as `<file>.md` alongside `<file>.json` and `diagram.mmd` (`scripts/run_analysis_pipeline.ps1:1250-1253`). The web-viewer's `outputs.js` already resolves any `.md` output reference to `outputs.markdown`, rendered under a "Narrative" section — that plumbing exists and is currently just unused because `markdown_report` is so often empty.

## Goals / Non-Goals

**Goals:**
- Add `narrative_writer` as a tenth stage producing a reliable, purpose-focused `<file>.md`, independent of `architecture_spec_writer`'s JSON output budget.
- Minimize the blast radius of inserting a new stage into a script that identifies stages by both name and hardcoded array index.
- Keep the two agent-roster copies (`$StageAgents`, `$AgentNames`) and the four OpenSpec capability specs that hardcode "nine" in sync with the new count.

**Non-Goals:**
- Per-procedure narrative generation (flagged in the proposal as future follow-up).
- Any web-viewer code changes — only manual verification that `outputs.markdown` renders correctly once a real `.md` narrative exists.
- Backfilling `.md` narratives for already-completed files.

## Decisions

**Append, don't insert.** `narrative_writer` becomes `$StageAgents[8]`, running immediately after `diagram_designer_context_visualizer` (still `$StageAgents[7]`, untouched) and immediately before `architecture_spec_writer`, which shifts from index 8 to index 9. Inserting *before* the diagram stage would instead require renumbering every index reference from 7 through 8 (six call sites); appending only requires bumping the four existing `$StageAgents[8]` references (`run_analysis_pipeline.ps1:1239-1272`) to `[9]` and adding one new resume-gated block for stage 8, mirroring the diagram stage's existing `if ($resumeIndex -le 7) { ... }` pattern at `-le 8`. Smaller, more mechanical diff, same effective position in the chain (diagram and narrative are siblings either way — both read the same six raw findings, neither depends on the other).

**Standalone `.md` file, not a JSON field — reuse the existing write pattern exactly.** `narrative_writer`'s output is written the same way `diagram.mmd` is today (`Write-Utf8NoBom` directly to `$outDir`, no JSON parsing/repair needed), as `<file>.md` using the naming convention `architecture_spec_writer` already established for `markdown_report`'s output file (`"$leafName.md"`). This is a plain-text stage output like the diagram, not a structured one — no `Repair-JsonTruncation`/`Repair-JsonEscapes` handling needed, which is also one less failure mode than what `markdown_report` had as an embedded JSON string.

**Same inputs as the diagram stage, unchanged.** `narrative_writer` receives the identical `$userContent` composition already built for the diagram call (`business domain, structural, logic, security, performance, test validation`) rather than deriving a new context-assembly path. One new system prompt variable (`$NarrativeWriterSystemPrompt`), one new `Invoke-Stage` call, reusing everything else.

**`architecture_spec_writer` loses `markdown_report` entirely** — field, instruction sentence, and the `if ($parsed.markdown_report) { ... }` write branch (`run_analysis_pipeline.ps1:1249-1254`) — rather than keeping it as a redundant fallback. Two stages racing to write the same `<file>.md` would be confusing (which one wins? silently overwritten?) and defeats the point of moving the responsibility.

**Two hardcoded roster copies, updated together, not unified.** `$AgentNames` (`generate_analysis_queue.ps1`) and `$StageAgents` (`run_analysis_pipeline.ps1`) already tolerate this duplication (different files, different purposes — one seeds the initial manifest template, one drives execution). Unifying them (e.g. one file `dot-source`s the other's list) is a bigger refactor than this change needs; both get `"narrative_writer"` added by hand, in the same relative position (after `diagram_designer_context_visualizer`, before `architecture_spec_writer`), and a task explicitly calls out verifying both stay consistent.

## Risks / Trade-offs

- **[Risk] A future contributor edits `$StageAgents` without noticing `$AgentNames` needs the same change (or vice versa) → a newly-discovered file's manifest entry is missing a `token_usage.agents.narrative_writer` key, and `Update-ManifestEntry`'s sync loop (`if ($entry.token_usage.agents.($agentName) -and ...)` at `run_analysis_pipeline.ps1:943`) silently no-ops for that agent instead of erroring.** → Mitigation: a task explicitly checks both lists end up identical (order and membership) after this change; the risk isn't eliminated but is caught once, now, rather than needing a structural fix.
- **[Risk] Renumbering `$StageAgents[8]` → `[9]` at four call sites is easy to get subtly wrong (miss one, leaving a stale reference to `narrative_writer` where `architecture_spec_writer` was meant).** → Mitigation: grep for `StageAgents\[8\]` after the edit — should return zero matches; grep for `StageAgents\[9\]` — should return exactly the four (now five, including the new resume-check) sites that meant the final stage.
- **[Risk] `narrative_writer`'s prose quality is untested until a real pipeline run.** → Mitigation: this is inherent to prompt-engineering an LLM stage; out of scope for design, addressed by a manual-verification task (run against a handful of real files, read the output, confirm it reads as purpose-focused rather than a rehash) rather than an automated check.
- **[Trade-off] Running `narrative_writer` as a genuinely separate stage costs one more model call per file** (vs. trying to just fix `markdown_report` in place) → accepted per the proposal's rationale: the current single-call approach is where the reliability problem comes from, and splitting is the whole point.

## Migration Plan

No data migration — this only affects files processed *after* the change ships. Already-completed files simply have no `.md` narrative (same as most of them do today, since `markdown_report` was already usually empty) until reprocessed. No rollback concerns beyond reverting the code change; nothing this stage writes is consumed by anything else in the pipeline (narrative_writer has no downstream dependents within the chain — `architecture_spec_writer` explicitly does not receive the diagram output today, and won't receive the narrative either).

## Open Questions

- Exact wording/length target for the narrative prompt — left to implementation; the proposal's guidance (purpose-focused, grounded in business domain + business logic findings, structural entry points used only for grounding) is the constraint, not a literal prompt draft.
- Whether `narrative_writer`'s own intermediate output also needs `Save-Intermediate` (the diagram stage saves its raw output as an intermediate in addition to writing `diagram.mmd`) — recommend yes, for consistency with every other stage, decided during implementation rather than blocking design.
