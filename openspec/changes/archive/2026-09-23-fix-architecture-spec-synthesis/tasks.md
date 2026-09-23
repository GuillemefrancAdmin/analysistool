## 1. Prompt fix (`scripts/run_analysis_pipeline.ps1`)

- [x] 1.1 Rewrite `$ArchitectureSpecSystemPrompt`'s `functional_requirements` shape description to an array-of-structured-objects example matching `templates/source-code-analysis-schema.json`'s actual required fields (`requirement_id`, `business_rule_type`, etc.), using bracketed placeholder tokens (e.g. `<string, e.g. REQ-001>`) rather than plausible prose that could be echoed verbatim.
- [x] 1.2 Do the same rewrite for `technical_debt_and_code_smells`.
- [x] 1.3 Add one explicit instruction sentence marking the shape block as a format template, never to be copied verbatim, and stating that an empty array is the correct output when a section has no real findings.
- [x] 1.4 Audit and, if it doesn't cost significant extra prompt complexity, apply the same structured-shape + anti-echo treatment to `external_library_dependencies` and `database_interactions` (measured healthier but sharing the same underlying pattern).
- [x] 1.5 Cross-check the rewritten example against `templates/source-code-analysis-schema.json` field-by-field to confirm exact conformance (required fields, enum values).

## 2. Retroactive re-synthesis mechanism (`scripts/backfill_new_stage.ps1`)

- [x] 2.1 Add an `-EvenIfAlreadyRun` switch parameter.
- [x] 2.2 When set, change the target-selection predicate from `$_.status -eq "completed" -and (-not ...model_name)` to just `$_.status -eq "completed"` for the given `-NewStageName`.
- [x] 2.3 Verify the report-only (no `-Force`) path correctly reports the full completed-file count as targets when run with `-NewStageName architecture_spec_writer -EvenIfAlreadyRun`, without writing anything. Confirmed: 1578/1578 targeted, nothing written.
- [x] 2.4 Update the script's header comment to describe the broadened purpose (propagating a new stage OR force re-running an existing one), not just the original new-stage-backfill use case.

## 3. Verification script (`scripts/verify_synthesis_quality.ps1`, new)

- [x] 3.1 Create a read-only script, structured similarly to `queue_eta.ps1`, that iterates every completed file's output JSON under `.analysis-state/outputs/`.
- [x] 3.2 For each file, run `Test-Json -SchemaFile templates/source-code-analysis-schema.json` and record pass/fail. (Extended beyond the original plan: also separately tracks *why* a file fails -- missing required top-level sections vs. other reasons -- since implementation revealed the schema requires 4 top-level sections, `source_evidence`/`execution_context`/`interface_contracts`/`token_usage`, that the prompt has never asked for at all, pre-existing and unrelated to this fix. Confirmed with user: keep this fix scoped, make the report separate the two concerns rather than let the unrelated gap make this fix look like it failed.)
- [x] 3.3 Separately detect literal placeholder text in `functional_requirements`/`technical_debt_and_code_smells` (same detection approach used to produce this change's measurement) and record a placeholder-rate count independent of schema validity. Also detects the new fixed-prompt's own placeholder pattern (`new_placeholder`) and old-shape-but-non-placeholder content (`wrong_shape`), not just a binary real/placeholder split.
- [x] 3.4 Print a summary report: total files checked, schema-valid count/%, placeholder-free count/% per field. Verified against a 51-file sample (GESACAD/cobol): 96.1% old_placeholder on both target fields, 100% missing the 4 unrelated top-level sections, 0% new_placeholder (correct pre-rerun baseline).

## 4. Rollout and measurement

- [x] 4.1 Run `verify_synthesis_quality.ps1` once before any other change lands, to record the current baseline (91.0% / 97.3% placeholder, expected to reconfirm the measurement in this change's proposal). Confirmed at full corpus scale (1578/1578 files): 96.2%/96.1% old_placeholder, 2.2%/2.2% wrong_shape, 1.5%/1.3% empty, only 0.1%/0.4% real. Also surfaced the separate missing-top-level-sections gap (source_evidence/execution_context/interface_contracts/token_usage, 100% of files) -- see design.md Open Questions.
- [x] 4.2 Ship the prompt fix (section 1).
- [x] 4.3 Run `backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun` report-only, confirm the target count matches the completed-file count, then re-run with `-Force`. Report-only confirmed 1578/1578 (task 2.3); user approved after out-of-band validation (task 4.6) passed. `-Force` run completed: 1578/1578 rewound. `queue_eta.ps1` confirms manifest health: 0 completed, 1578 queued, 0 blocked, 0 in_progress.
- [ ] 4.4 Re-run the pipeline (`run_analysis_pipeline_parallel.ps1`) to let workers process the now-`queued` files, resuming at `architecture_spec_writer` only. **Deferred to user by request** ("stop it i will rerun it manually") -- corpus is staged and ready; not started here.
- [ ] 4.5 Run `verify_synthesis_quality.ps1` again and compare against the section 4.1 baseline. Blocked on 4.4 running to completion.
- [x] 4.6 Spot-check a handful of re-synthesized files' `functional_requirements` by hand to confirm the content reads as real, file-specific business rules rather than a subtler form of generic filler. Done out-of-band (real saved intermediates, new prompt, no manifest/state touched) against 3 files spanning all 3 subsystems (Gesacad cobol, Sigare 4gl, SIgare Web php) before committing the corpus-wide rewind: all three produced real, specific, correctly-structured `functional_requirements`/`technical_debt_and_code_smells` (actual table/variable names, concrete line ranges, grounded security findings) -- e.g. "Insert hourly codes from HOR_ACTIVITE and CONTRAT into TT_T_CODES_HOR", "Hardcoded username and node in EXEC SQL CONNECT statement". One minor, non-blocking observation: one item used a `category` value (`sql_injection_risk`) outside the schema's enum (should be `security_vulnerability`) -- noted, not a regression from this fix, not worth blocking on.
