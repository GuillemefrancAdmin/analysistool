## Context

`$ArchitectureSpecSystemPrompt` (`scripts/run_analysis_pipeline.ps1`) already got one rewrite this session (`fix-architecture-spec-synthesis`): its `functional_requirements`/`technical_debt_and_code_smells`/`external_library_dependencies`/`database_interactions` sections now use bracketed-placeholder-token format templates with an explicit anti-echo instruction, instead of plausible-prose examples the model was echoing back verbatim. That fix's own `verify_synthesis_quality.ps1` tool, run against the full corpus, additionally revealed that `source_evidence`, `execution_context`, `interface_contracts`, and `token_usage` are missing from the prompt's shape entirely — present in 0 of 1,578 files — a separate, pre-existing gap that change deliberately left out of scope.

`token_usage`'s schema shape (`run_total_tokens`, `run_total_elapsed_seconds`, `agents` keyed by name with `model_name`/`started_at`/`ended_at`/`elapsed_seconds`/token counts) is structurally identical to `$state.token_usage`, already populated throughout the file's processing by `Set-AgentTiming` (called after every stage, including `architecture_spec_writer` itself). By the time the final-synthesis block runs, `$state.token_usage` already has the complete, accurate record for this file.

This codebase has an established, documented workaround for adding a property to a `ConvertFrom-Json`-produced object under Windows PowerShell 5.1 (`run_analysis_pipeline.ps1`'s own `Update-ManifestEntry`, around the `$entry.last_completed_stage = ...` block): plain assignment throws "property ... cannot be found" for a property that doesn't already exist; `Add-Member -Force` works for both the first-time-add and later-update case identically.

## Goals / Non-Goals

**Goals:**
- Bring the prompt's requested shape to full parity with the schema's 16 required top-level sections.
- Get `token_usage` populated with genuinely accurate data (the orchestration script's own record) rather than asking a model to estimate something it has no way to know.
- Fix the observed `category` enum violation as a small, low-risk addition to the same prompt block already being touched.

**Non-Goals:**
- Re-litigating `fix-architecture-spec-synthesis`'s own fields (`functional_requirements` etc.) — already fixed, out of scope here.
- A general schema-validation gate (blocking/retrying on `Test-Json` failure) — still explicitly deferred, same reasoning as before: this change makes the *content* schema-complete, not the pipeline's failure-handling stricter.
- The separate unescaped-quote JSON-syntax issue — its own change (`fix-unescaped-quote-json-repair`).

## Decisions

**`source_evidence`/`execution_context`/`interface_contracts` go into the prompt using the bracketed-placeholder-token convention, not the old prose-example style.** Directly reuses the format `fix-architecture-spec-synthesis` already established and validated (out-of-band, against 3 real files) for avoiding the echo failure — no reason to reintroduce the old, confirmed-broken pattern for new sections.

**`token_usage` is injected by the script, never added to the prompt at all.** The model has no way to accurately know its own historical token/timing usage across all ten stages; asking it to fabricate a plausible-looking value would just recreate the exact failure mode this session has spent most of its effort fixing. `$parsed | Add-Member -NotePropertyName token_usage -NotePropertyValue $state.token_usage -Force`, placed immediately after the existing `$parsed.module_metadata.file_path = $relativePath` line (same block, same established pattern, trivial diff).
- *Alternative considered*: ask the model to leave `token_usage` as a stub the script then overwrites. Rejected — pure wasted prompt complexity and output tokens for a value that's discarded unconditionally; omitting it from the prompt entirely is strictly simpler.

**Enum reinforcement is one added sentence in the existing anti-echo instruction block** ("...and every enum-typed value must be exactly one of its listed options, never a value outside that list"), not a new validation mechanism. A single observed instance doesn't justify programmatic enum-checking machinery; the existing prompt-level fix pattern (clearer instructions) is the proportionate response, with `verify_synthesis_quality.ps1`'s `Test-Json` check (which does enforce enum membership) available to measure whether it worked.

## Risks / Trade-offs

- **[Risk] Three more prompt sections means a longer system prompt and larger expected output, on an 8B model already producing occasionally-truncated JSON (`Repair-JsonTruncation` exists for exactly this).** → Mitigation: `verify_synthesis_quality.ps1`'s parse-error count (already tracked) is the signal to watch after this ships; if truncation increases noticeably, the next move is examining `-MaxTokensPerStage` for this stage specifically, not part of this change.
- **[Trade-off] This is a third full-corpus `architecture_spec_writer`-only re-run** (after `fix-architecture-spec-synthesis`'s own re-run, itself already in progress and unable to include this fix). Accepted — same reasoning as before: the fix is cheap per-file (a few seconds, one stage), and the alternative (leaving 100% of the corpus without these sections indefinitely) is worse.

## Migration Plan

1. Ship the prompt + injection changes.
2. Run `backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun` (report-only first, then `-Force`) — same mechanism, same stage, as `fix-architecture-spec-synthesis`.
3. Re-run the pipeline.
4. Run `verify_synthesis_quality.ps1` and confirm the whole-document `Test-Json` pass rate has moved from its `fix-architecture-spec-synthesis`-era baseline (0%, entirely due to these missing sections) to something meaningfully higher.

No rollback complexity beyond reverting the prompt/script changes — same reasoning as `fix-architecture-spec-synthesis`'s migration plan (the rewind only touches `last_completed_stage`/`status`, nothing destructive).

## Open Questions

- Exact wording for the three new sections and the enum-reinforcement sentence — implementation-time decision, consistent with how prompt wording has been treated throughout this session.
