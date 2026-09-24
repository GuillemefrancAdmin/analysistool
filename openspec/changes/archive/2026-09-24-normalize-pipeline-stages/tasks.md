## 1. Shared stage registry

- [x] 1.1 Create `scripts/pipeline_stages.ps1` defining the ordered middle-stage table `$PipelineStages` (one entry per stage from `business_domain_extractor` through `narrative_writer`), each with `Name`, `SystemPromptVar`, `Inputs` (ordered list of prior stage names + their exact current label text, e.g. `"BUSINESS DOMAIN:"`), and optional `SiblingOutput`.
- [x] 1.2 In the same file, define `$SanitizerStageName` and `$FinalSynthesisStageName` constants for the two bespoke endpoint stages.
- [x] 1.3 Add `Get-AllAgentNames` (returns `file_queue_orchestrator_agent` + sanitizer + `$PipelineStages` names + final synthesis, in order) - the single source of truth both scripts will use.
- [x] 1.4 Add `New-EmptyAgentUsage` (the canonical 7-field empty per-agent `token_usage` record: `model_name`, `started_at`, `ended_at`, `elapsed_seconds`, `prompt_tokens`, `completion_tokens`, `total_tokens`).

## 2. Pipeline runner (`scripts/run_analysis_pipeline.ps1`)

- [x] 2.1 Dot-source `pipeline_stages.ps1`; replace the `$StageAgents` literal with a value built from `Get-AllAgentNames` (minus `file_queue_orchestrator_agent`, matching today's `$StageAgents` scope).
- [x] 2.2 Replace the per-stage `$sanitized`/`$domain`/`$structure`/.../`$diagram`/`$narrative` variable declarations with a single `$results = @{}` hashtable keyed by stage name.
- [x] 2.3 Replace the resume-rehydration block (the `if ($resumeIndex -gt N) { $x = Get-SavedStage $StageAgents[N] }` lines) and the eight hand-written middle-stage execution blocks (`business_domain_extractor` through `narrative_writer`) with one loop over `$PipelineStages` that: rehydrates from intermediates when already past that stage, otherwise composes labeled input from `$stage.Inputs` and `$results`, calls `Invoke-Stage`, saves the intermediate, advances `last_completed_stage`, and writes `$stage.SiblingOutput` when present.
- [x] 2.4 Keep the sanitizer stage (reads raw source, not prior results) and the final synthesis stage (JSON parse/repair/validate, completion/blocking decision) as their own dedicated code, now referencing `$SanitizerStageName`/`$FinalSynthesisStageName` instead of `$StageAgents[0]`/`$StageAgents[9]`.
- [x] 2.5 Update the final synthesis block's `output_references` assembly to check for sibling outputs generically (iterate stages with a `SiblingOutput` defined) instead of the two hand-copied `Test-Path` blocks for `diagram.mmd` and `<file>.md`.
- [x] 2.6 Replace `Set-AgentTiming`'s inline defensive-fallback hashtable literal with a call to `New-EmptyAgentUsage`.

## 3. Queue generator (`scripts/generate_analysis_queue.ps1`)

- [x] 3.1 Dot-source `pipeline_stages.ps1`; replace the `$AgentNames` literal with `Get-AllAgentNames`.
- [x] 3.2 Replace `Get-EmptyAgentUsage`'s body with a call to the shared `New-EmptyAgentUsage` (or remove `Get-EmptyAgentUsage` entirely and call the shared function directly at its call site).
- [x] 3.3 Update `Get-AgentSummary` to build its default record from `New-EmptyAgentUsage` before overlaying any existing values, instead of its own separate hashtable literal.

## 4. Backfill tool

- [x] 4.1 Create `scripts/backfill_new_stage.ps1 -NewStageName <name>` that looks up `<name>`'s position in the shared registry, finds every manifest entry with `status: completed` whose `last_completed_stage` is at or after that position, and reports the count with no writes by default.
- [x] 4.2 Add `-Force` (or equivalent) to actually perform the rewind: for each matched file, set `last_completed_stage` to the immediately-preceding registry stage, `status: queued`, zero `run_total_tokens`/`run_total_elapsed_seconds`, on both the state file and the manifest entry, writing both with the existing `Write-Utf8NoBom` helper (no BOM).
- [x] 4.3 Verify it leaves per-agent history for stages before the rewind point untouched, and leaves files not matching the target status/stage criteria untouched.

## 5. Verification

- [x] 5.1 Confirm no live `run_analysis_pipeline*.ps1` worker is running (check `.analysis-state/locks/`) before making these changes, since they touch scripts a live worker may have loaded.
- [x] 5.2 `-DryRun` against a file rewound mid-chain (same technique as the previous change's resumability check) and confirm it reports the correct next stage.
- [x] 5.3 Fully reprocess one small file end to end and confirm its resulting `.json`, `.md`, and `diagram.mmd` match the shape and content quality of files processed before this refactor (allowing for normal model non-determinism in the exact wording).
- [x] 5.4 Run `scripts/backfill_new_stage.ps1 -NewStageName narrative_writer` in report-only mode against the current manifest and confirm its count matches the number of files still missing a narrative from the previous change's manual backfill (0, if that backfill already completed; otherwise the remaining count).
- [x] 5.5 Confirm `generate_analysis_queue.ps1` still runs cleanly end to end (rescans the full source tree, writes the manifest) with no behavior change for already-tracked files.
