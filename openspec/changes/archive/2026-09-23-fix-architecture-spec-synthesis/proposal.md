## Why

`architecture_spec_writer`'s system prompt shows its target JSON shape as one literal example object, with format-spec placeholder text written in as if it were a real filled value — e.g. `"functional_requirements": ["REQ-ID | title | computation|validation|... | short description"]`. Nothing distinguishes "this is a format description" from "this is an example answer," and the small local model (`llama3.1:8b`) very often just echoes it back verbatim instead of synthesizing real content. Measured across the entire completed corpus (not a sample): **91.0% of 1,578 completed files have a literal placeholder `functional_requirements` entry, and 97.3% have a literal placeholder `technical_debt_and_code_smells` entry.** This holds consistently across all three legacy subsystems (87–92% / 93–98%) and isn't a context-truncation artifact — files with placeholder output actually had *larger* upstream findings on average, and fields synthesized later in the same JSON document are usually filled with real content. The failure is specific to these two fields' prompt design, not a model-capability ceiling.

There's a second, independent bug in the same block: the prompt's example represents `functional_requirements` and `technical_debt_and_code_smells` as flat pipe-delimited **strings**, but `templates/source-code-analysis-schema.json` requires arrays of structured **objects** (`requirement_id`, `business_rule_type`, etc.). So even the small fraction of files with non-placeholder content is very likely in the wrong shape relative to the schema's actual requirement.

This matters acutely now: the project's migration target is a **rewrite** (new stack, same business logic), which makes `functional_requirements` — the one field capturing extractable business rules — the single most load-bearing deliverable of the entire pipeline. It is currently unusable for ~91% of the corpus already processed.

## What Changes

- Rewrite the `functional_requirements` and `technical_debt_and_code_smells` sections of `$ArchitectureSpecSystemPrompt` (`scripts/run_analysis_pipeline.ps1`) so the embedded shape (a) matches the real schema's array-of-structured-objects requirement instead of pipe-delimited strings, and (b) is unambiguously marked as a format template rather than example content the model can copy verbatim — plus an explicit instruction that an empty array is the correct output when a section has no real findings, rather than inventing or echoing placeholder content.
- Audit the same prompt's other fields that use the identical "placeholder-text-as-example" pattern (`dependencies_and_integrations.external_library_dependencies`, `database_interactions`) — these measured healthier (78–90% real content) but share the same underlying weakness and should be brought in line with the same fix for consistency, even though they're not this proposal's primary driver.
- **BREAKING**: the shape of `functional_requirements` and `technical_debt_and_code_smells` in newly-produced output changes from flat pipe-delimited strings to structured objects, matching `templates/source-code-analysis-schema.json` (which never actually changes — this aligns the prompt to the schema that already existed).
- Add a mechanism to re-run `architecture_spec_writer` alone against already-completed files (reusing their saved stage intermediates, not re-running the six upstream analysis stages), since `backfill_new_stage.ps1`'s existing rewind logic only targets files that have *never* recorded a given stage — every one of the 1,578 completed files already has a real (if low-quality) `architecture_spec_writer` result, so the existing backfill tool's selection criteria would match none of them.

Explicitly out of scope: the separate ~1.9%-of-completed-files unescaped-embedded-quote JSON-parse-failure issue (confirmed a distinct, purely syntactic root cause, unrelated to this placeholder/schema problem) — noted here as a follow-up, not part of this change.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `legacy-source-analysis-agents`: the "Architecture-spec-writer owns final schema synthesis" requirement gains an explicit constraint that synthesized content must be derived from the actual upstream findings (never the prompt's own format-template text) and must match the schema's structured shape for `functional_requirements` and `technical_debt_and_code_smells`.

## Impact

- `scripts/run_analysis_pipeline.ps1`: rewrite the `functional_requirements`/`technical_debt_and_code_smells` (and, for consistency, `external_library_dependencies`/`database_interactions`) sections of `$ArchitectureSpecSystemPrompt` (currently lines 321-346).
- A new or extended script for re-running `architecture_spec_writer` alone against already-`completed` files, reusing saved intermediates — exact mechanism (new script vs. extending `backfill_new_stage.ps1`) to be decided in design.
- `templates/source-code-analysis-schema.json`: no change (the prompt is being aligned to the existing schema, not the other way around) — but worth a final cross-check that the rewritten prompt example is byte-for-byte consistent with the schema's actual field definitions.
- Already-completed files in `.analysis-state/outputs/` are affected retroactively *if* the re-synthesis mechanism above is used against them — this is the point of adding it, unlike the narrative-writer change which explicitly left old files unbackfilled.
