## Why

`templates/source-code-analysis-schema.json` requires 16 top-level sections; `$ArchitectureSpecSystemPrompt` has only ever asked for 13. `source_evidence`, `execution_context`, `interface_contracts`, and `token_usage` are missing entirely — confirmed present in 0 of 1,578 completed files (`verify_synthesis_quality.ps1`, run during `fix-architecture-spec-synthesis`). This means every file's output fails whole-document schema validation today, for a reason unrelated to that change's placeholder-echo fix.

The four missing sections split into two different kinds of gap:
- `source_evidence`, `execution_context`, and `interface_contracts` are genuinely LLM-derivable (symbol names/line ranges/confidence, entrypoint type and trigger mechanism, input/output schemas) — the prompt simply never asks for them, the same class of gap `fix-architecture-spec-synthesis` already fixed for two other fields.
- `token_usage` is different in kind: its schema shape (`run_total_tokens`, `run_total_elapsed_seconds`, per-agent `model_name`/timing/token breakdown) is *exactly* what `run_analysis_pipeline.ps1` already tracks in `$state.token_usage` for every file, via the same `Set-AgentTiming` calls that populate the manifest. This isn't something the model should be asked to report on itself — it's API call metadata the orchestration script already has, more accurately than an LLM could ever self-report it.

## What Changes

- Add `source_evidence`, `execution_context`, and `interface_contracts` to `$ArchitectureSpecSystemPrompt`'s shape, using the same bracketed-placeholder-token format-template convention `fix-architecture-spec-synthesis` established (not the old plausible-prose-as-example pattern), so the model derives real content instead of risking the same echo failure this session already fixed once.
- After parsing `architecture_spec_writer`'s response, inject `$state.token_usage` into `$parsed.token_usage` directly in the script — no model involvement, no prompt change for this field. Uses `Add-Member -Force` (not plain assignment), matching this script's own established workaround for adding a property a `ConvertFrom-Json` object doesn't already have under Windows PowerShell.
- Reinforce enum-value conformance in the prompt (a `technical_debt_and_code_smells.category` value outside the schema's enum, `sql_injection_risk` instead of `security_vulnerability`, was observed during `fix-architecture-spec-synthesis` validation) — small addition to the same prompt block, not its own change.
- Re-run `verify_synthesis_quality.ps1` before/after to confirm the whole-document `Test-Json` pass rate actually moves, not just the two fields the prior change targeted.

Retroactive re-synthesis of already-completed files (same `backfill_new_stage.ps1 -EvenIfAlreadyRun` mechanism `fix-architecture-spec-synthesis` added) is included. `fix-architecture-spec-synthesis`'s corpus-wide re-run is already in progress and started before this change exists, so every file it processes will still be missing these four sections — this change's own backfill pass is expected to be a third full-corpus `architecture_spec_writer`-only re-run, not something to avoid this time.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `legacy-source-analysis-agents`: `architecture-spec-writer`'s owned-schema-sections requirement grows to include `source_evidence`, `execution_context`, and `interface_contracts` (LLM-derived) and `token_usage` (script-injected from already-tracked state, not model-derived).

## Impact

- `scripts/run_analysis_pipeline.ps1`: extend `$ArchitectureSpecSystemPrompt`'s shape (3 new sections + enum reinforcement); add `Add-Member -Force` injection of `$state.token_usage` into `$parsed` right after the existing `$parsed.module_metadata.file_path = $relativePath` line.
- No schema changes — the schema already defines all four sections correctly; the prompt and script are being brought in line with it.
- Same retroactive-resynthesis consideration as `fix-architecture-spec-synthesis`: best sequenced before that change's pipeline re-run, to avoid two separate full-corpus passes.
