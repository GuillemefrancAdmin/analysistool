## Context

Adding `narrative_writer` (the previous change) touched: `$StageAgents` in `run_analysis_pipeline.ps1`, `$AgentNames` in `generate_analysis_queue.ps1` (a second, hand-synchronized copy of the same roster), a new hand-written per-stage block copy-pasted from the diagram stage's, four hardcoded `$StageAgents[8]` references that had to be renumbered to `[9]`, and a new resume-gate/rehydration line each hardcoded to its own stage index. It also surfaced a real, pre-existing bug: three separate functions independently hand-built "what does an empty per-agent `token_usage` record look like" (`Get-AgentSummary`, `Get-EmptyAgentUsage`, and the fallback this session added to `Set-AgentTiming`), and two of the three were missing two of the schema's seven required fields. None of this had anything to do with what `narrative_writer` actually does - it was all mechanical overhead in *adding* a stage.

The middle of the chain (`business_domain_extractor` through `narrative_writer`, i.e. everything except the sanitizer and the final JSON synthesis) already shares one shape: compose a labeled `$userContent` from some subset of prior stages' results, call `Invoke-Stage`, save the intermediate, advance `last_completed_stage`, optionally write one extra sibling file (`diagram.mmd`, `<file>.md`). `sanitizer_context_ingestion_agent` (reads the raw source file, not prior stage output) and `architecture_spec_writer` (parses/repairs/validates JSON, decides completed-vs-blocked, assembles the final `output_references`) are each genuinely one-of-a-kind and stay hand-written.

## Goals / Non-Goals

**Goals:**
- One place declares the stage roster; both scripts that need it read from there.
- Adding a stage to the generic middle section (the common case) means adding one table entry, not touching N call sites.
- Stage identity and resume gating are computed from the stage's own name, never a numeric literal, so nothing needs renumbering when a stage is inserted.
- One canonical function builds an empty per-agent `token_usage` record; nothing hand-rolls its own copy.
- Adding a stage to an already-completed queue has a supported, tested backfill path instead of hand-written JSON surgery.

**Non-Goals:**
- Changing any existing stage's behavior, prompt, inputs, or position in the chain. This is a mechanical/organizational refactor; every stage does exactly what it does today.
- Forcing the sanitizer or the final JSON-synthesis stage into the generic shape - they're legitimately different in kind, and bending them to fit would make the code harder to follow, not easier.
- Changing anything about already-completed files' on-disk data.

## Decisions

**A new shared file, `scripts/pipeline_stages.ps1`, dot-sourced by both scripts.** It defines: the ordered stage table (`$PipelineStages`, one entry per stage from `business_domain_extractor` through `narrative_writer` - the generic middle section), the two endpoint stage names as separate constants (`$SanitizerStageName`, `$FinalSynthesisStageName`) so both scripts can still reference them by name without re-hardcoding the literal strings, a `Get-AllAgentNames` function returning the full roster including `file_queue_orchestrator_agent` and both endpoints in the correct order (what `generate_analysis_queue.ps1`'s `$AgentNames` is today), and the one canonical `New-EmptyAgentUsage` function. Plain dot-sourcing (`. (Join-Path $PSScriptRoot "pipeline_stages.ps1")`) rather than a `.psm1` module - matches how this codebase already works (no existing script uses PowerShell modules), smallest possible change to each script's own structure.

**Each middle-stage table entry is a hashtable with:** `Name` (e.g. `"narrative_writer"`), `SystemPromptVar` (the variable name holding its prompt, e.g. `"NarrativeWriterSystemPrompt"` - resolved via `Get-Variable` at call time, since the prompts themselves stay as top-level `@'...'@` strings in `run_analysis_pipeline.ps1` for readability, not moved into the data file), `Inputs` (an ordered list of prior stage names whose results get concatenated as labeled sections - e.g. `@("sanitizer_context_ingestion_agent")` for `business_domain_extractor`, or all six raw-finding stage names for `diagram_designer_context_visualizer`/`narrative_writer`), and an optional `SiblingOutput` scriptblock/pattern (e.g. `{ param($leafName) "$leafName.md" }`, or the literal `"diagram.mmd"`) for stages that write an extra file beyond the standard intermediate.

**Results keyed by stage name in a hashtable (`$results`), not one hand-declared variable per stage.** Replaces `$sanitized`/`$domain`/`$structure`/.../`$narrative` with `$results['business_domain_extractor']` etc. A new middle stage needs no new variable declaration anywhere - it just becomes a new key the generic loop fills in. The two endpoint stages still get convenience local variables (`$sanitized`, `$rawReport`) since their handling stays bespoke.

**One generic loop replaces the eight (soon nine, ten, ...) hand-copied middle-stage blocks:**
```
foreach ($i in 0..($PipelineStages.Count - 1)) {
    $stage = $PipelineStages[$i]
    if ($resumeIndex -gt $i) { $results[$stage.Name] = Get-SavedStage $stage.Name; continue }
    if ($resumeIndex -gt $i -or $resumeIndex -eq $i) { ... } # exact gate per existing -le semantics
    $userContent = Build-StageInput -Stage $stage -Results $results   # labeled concatenation from $stage.Inputs
    $output = Invoke-Stage -AgentName $stage.Name -SystemPrompt (Get-Variable $stage.SystemPromptVar -ValueOnly) -UserContent $userContent ...
    Save-Intermediate ...; $results[$stage.Name] = $output
    $state.last_completed_stage = $stage.Name; Save-State ...
    if ($stage.SiblingOutput) { Write-Utf8NoBom -Path (Join-Path $outDir (& $stage.SiblingOutput $leafName)) -Content (Remove-CodeFence $output) }
}
```
Resume rehydration (today's block of `if ($resumeIndex -gt N) { $x = Get-SavedStage ... }` lines) collapses into the same loop's `continue`-on-already-done branch - one loop does both rehydration and fresh execution, rather than two separate hand-written sections that both need a new line per stage.

**`Update-ManifestEntry`'s per-agent sync loop and the state-seeding functions call `Get-AllAgentNames`/`New-EmptyAgentUsage` instead of their own literals.** `Get-AgentSummary` keeps its own logic (overlay existing values onto defaults) but its base defaults come from `New-EmptyAgentUsage` instead of a second hand-written hashtable literal.

**The backfill tool is a new script, `scripts/backfill_new_stage.ps1 -NewStageName <name>`,** not a flag bolted onto an existing script (existing scripts have enough responsibility already; this is a distinct, occasional, explicit operator action, not something that should be reachable by accident via a flag on the main runner). It looks up `<name>`'s position in `$PipelineStages` itself (via the shared registry - no need for the caller to know or pass "the stage before it"), and for every manifest entry with `status: completed` whose `last_completed_stage` is at or after that position: rewinds `last_completed_stage` to the immediately-preceding stage's name, sets `status: queued`, zeroes `run_total_tokens`/`run_total_elapsed_seconds` on both the state file and the manifest entry, and writes both with the codebase's existing `Write-Utf8NoBom` (no BOM - this session hit that exact bug hand-rolling the same operation with `Out-File -Encoding utf8`). `-WhatIf`/`-DryRun`-style reporting (count of files that would be touched, no writes) before committing, matching the existing `-DryRun` convention on the main runner.

## Risks / Trade-offs

- **[Risk] This refactor touches the same two files the in-flight `narrative_writer` backfill (1576 files, hours-long) may currently be running against.** A worker process holds the script's code in memory for the duration of its run; editing the `.ps1` files on disk doesn't affect an already-running process, but starting a *new* worker mid-backfill against a half-edited script would be a real problem. → Mitigation: a task explicitly checks for and documents coordination with any live run (via `.analysis-state/locks/`) before editing; this change should land either before the backfill starts or after it finishes, not concurrently.
- **[Risk] The generic loop's `Build-StageInput` must reproduce each stage's exact current label wording** (`"BUSINESS DOMAIN:"`, `"STRUCTURAL BREAKDOWN:"`, etc.) **or the prompts silently receive differently-formatted context than before.** → Mitigation: the label-per-stage-name mapping is itself part of the shared registry (each stage's `Inputs` entry pairs a stage name with its exact existing label), not re-derived or guessed; a verification task diffs a re-run of an already-completed file's stage inputs against its saved intermediates from before the refactor.
- **[Trade-off] The generic loop is one more layer of indirection than reading nine sequential, literal blocks top to bottom.** Accepted: the whole point of this change is that the previous shape made insertion error-prone, and that cost is paid once per stage addition, indefinitely, whereas the indirection is paid once in exchange for every future addition becoming a single table entry.
- **[Risk] `architecture_spec_writer`'s `Test-Path` checks for `diagram.mmd` and `<file>.md` today are two hand-copied blocks; folding "does this stage have a sibling output" into the generic table but leaving the final `output_references` assembly in the bespoke final-stage block creates a small seam (the table knows about sibling outputs, but the code that actually checks for them at the end doesn't read the table yet).** → Mitigation: the final assembly loop iterates `$PipelineStages | Where-Object SiblingOutput` generically too, so this doesn't become a third hand-copied thing.

## Migration Plan

Apply once no `run_analysis_pipeline*.ps1` worker is live (check `.analysis-state/locks/`). No data migration - existing state files, the manifest, and all output artifacts are untouched; this only reorganizes the scripts. After applying, verify by resuming a file mid-chain (same technique as the previous change's resumability check: rewind one file's `last_completed_stage`, `-DryRun`, confirm it reports the correct next stage) and by fully reprocessing one small file end to end, diffing its resulting `.json`/`.md`/`diagram.mmd` against what the pre-refactor code produced for the same file, to confirm byte-for-byte-equivalent behavior (modulo model non-determinism in the actual LLM text).

## Open Questions

- Exact `Build-StageInput` labeling mechanism (a lookup table of stage-name → label string alongside the registry, vs. a `Label` field directly on each *consumed* stage's own descriptor) - either works; decide during implementation based on which reads more clearly next to the existing prompt strings.
- Whether `backfill_new_stage.ps1` should also offer to zero the *new* stage's own agent record explicitly, or leave that to `Set-AgentTiming`'s existing defensive-create-on-first-use behavior (from the previous change) - likely redundant to do both, lean toward leaving it to the existing mechanism and confirming that during implementation.
