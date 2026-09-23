## Context

`architecture_spec_writer` is the pipeline's tenth and final stage (`scripts/run_analysis_pipeline.ps1`, `$ArchitectureSpecSystemPrompt` at lines 321-346). It receives the six upstream analysis stages' raw findings for one file and must compile them into the `LegacySourceCodeAnalysisReport`-shaped JSON defined by `templates/source-code-analysis-schema.json`. The prompt currently communicates that target shape as a single literal JSON example, with the shape *description* for `functional_requirements` and `technical_debt_and_code_smells` written as plausible-looking pipe-delimited string content (`"REQ-ID | title | computation|validation|..."`) rather than as a format spec distinguishable from a real answer. A corpus-wide measurement (all 1,578 completed files, not a sample) found 91.0% / 97.3% placeholder rates on these two fields respectively, consistent across all three legacy subsystems, and ruled out context-truncation as the cause (placeholder-output files had larger upstream findings on average; later-synthesized fields in the same document are usually real). The schema itself wants these two fields as arrays of structured objects, not strings — a second, independent mismatch between prompt and schema that predates this investigation.

The pipeline now runs under PowerShell 7 (via a relaunch guard added for an unrelated manifest-parsing reliability fix), which makes `Test-Json -SchemaFile` available for the first time — it doesn't exist in Windows PowerShell 5.1, which this pipeline ran under until recently.

`backfill_new_stage.ps1` already exists for rewinding completed files to right before a given stage so it can be re-run using already-saved intermediates, but its target-selection predicate (`-not $_.token_usage.agents.($NewStageName) -or -not ...model_name`) only matches files that have *never* recorded that stage — by design, since its purpose is propagating a newly-*added* stage to files that predate it. Every one of the 1,578 completed files already has a real (if content-poor) `architecture_spec_writer` result, so none would match today.

## Goals / Non-Goals

**Goals:**
- Stop the model from echoing the prompt's own format-template text as if it were real output, for `functional_requirements` and `technical_debt_and_code_smells` specifically (the two fields measured broken), and bring the other fields sharing the same pattern (`external_library_dependencies`, `database_interactions`) in line for consistency.
- Align the prompt's example shape for those fields with what `templates/source-code-analysis-schema.json` actually requires (structured objects, not pipe-delimited strings).
- Make the fix retroactively applicable to the 1,578 already-completed files without re-running the six upstream analysis stages (their intermediates are already saved on disk).
- Make it possible to *measure* whether the fix worked, without another slow manual sampling investigation.

**Non-Goals:**
- The separate unescaped-embedded-quote JSON-parse-failure issue (~1.9% of completed files, confirmed distinct root cause) — explicitly out of scope, noted as a follow-up.
- A hard schema-validation gate that blocks/retries files failing `Test-Json` — worth having eventually, but scoped here as a read-only *verification* tool only (see Decision 3), to keep this change about fixing the prompt, not about redesigning the pipeline's failure-handling state machine.
- Touching any of the six upstream analysis stages' prompts — they are not implicated by the measurement (their raw intermediates already contain real content; the loss happens specifically in synthesis).

## Decisions

**Rewrite the example as a format template, not a filled example — using bracketed placeholder tokens instead of plausible prose, plus an explicit anti-echo instruction.** Concretely, change:
```
"functional_requirements": ["REQ-ID | title | computation|validation|... | short description"]
```
to a structured-object shape matching the schema, with placeholder VALUES that read unambiguously as "fill me in," not as prose that could pass for a real requirement — e.g. `{"requirement_id": "<string, e.g. REQ-001>", "business_rule_type": "<one of: computation|validation|...>", ...}` — plus one explicit sentence: *"The shape above is a format template. Never copy its placeholder text into your output. Every value must come from the actual findings provided below; if a section has no real findings, output an empty array `[]`."* This directly targets the confirmed failure mode (verbatim echoing) rather than just improving wording quality, and fixes the schema mismatch in the same edit since the corrected example is now itself schema-conformant.
- *Alternative considered*: few-shot examples (a second, fully "realistic" filled example alongside the format spec) — more tokens per call, and risks the model anchoring on the *specific* example's content/domain rather than deriving from its own findings. Rejected in favor of the cheaper, more targeted bracketed-placeholder + explicit-instruction approach; revisit only if the simpler fix doesn't move the needle.

**Extend `backfill_new_stage.ps1` with a new `-EvenIfAlreadyRun` switch, rather than writing a new script.** When set, the target-selection predicate drops the "hasn't run yet" condition and becomes just `$_.status -eq "completed"` for the given `-NewStageName`; everything else (mutex-protected read/write, per-file state rewind to the preceding stage, report-only-unless-`-Force` dry run) is reused unchanged. This is a minimal, mechanical diff to an already-tested tool, and it's not architecture_spec_writer-specific — it generically supports "re-run stage X for all already-completed files" for any stage, which is a reusable capability for future prompt fixes, not just this one.
- *Alternative considered*: a new dedicated `resynthesize.ps1` script. Rejected — would duplicate the mutex/state-rewind logic that already exists and is already correctness-tested, for no functional benefit; the two use cases ("propagate a new stage" vs. "force re-run an existing one") differ only in one predicate, not in mechanism.
- Rewinding zeroes the file's whole-run token/time totals but leaves the stale per-stage `token_usage.agents.architecture_spec_writer` entry untouched until the stage actually reruns and overwrites it — identical, already-accepted behavior to the existing narrative-writer backfill precedent. No new risk.

**Add a read-only verification script (`scripts/verify_synthesis_quality.ps1`, modeled on `queue_eta.ps1`'s structure) that runs `Test-Json -SchemaFile templates/source-code-analysis-schema.json` plus a placeholder-text detector (reusing the same literal-string-match approach used in this change's own measurement) across all completed files' JSON outputs, reporting pass/fail counts.** This replaces "manually re-sample 40-50 files and eyeball them" with a fast, repeatable, whole-corpus check — usable both to confirm this fix worked and for any future prompt change to the same stage. Read-only; makes no pipeline-state decisions and blocks nothing.
- *Alternative considered*: build the same check into `run_analysis_pipeline.ps1` itself as a blocking gate (retry/block a file whose output fails validation). Rejected for this change specifically (Non-Goal above) — worth a future change once the corpus-wide numbers from this fix are in hand to judge whether gating is even still needed.

## Risks / Trade-offs

- **[Risk] The bracketed-placeholder rewrite reduces but may not eliminate echoing — an 8B model can still copy structural tokens like `<string>` literally into output.** → Mitigation: the verification script (Decision 3) measures the *actual* post-fix rate rather than assuming the fix worked; if the rate is still high, the next iteration is a prompt-wording problem to solve with the same measurement tool, not a re-investigation from scratch.
- **[Risk] `-EvenIfAlreadyRun` is a blunt instrument — running it against `architecture_spec_writer` rewinds literally all 1,578 completed files to "queued," discarding their current (bad) JSON only once the stage actually reruns, and consuming real GPU time for ~1,578 synthesis calls.** → Mitigation: this is the explicit, accepted cost of retroactive applicability (the proposal's stated goal); the report-only default (no `-Force`) lets this be sized/confirmed before committing, exactly like the existing backfill tool's normal usage pattern.
- **[Trade-off] Not gating on `Test-Json` now (Non-Goal) means a still-malformed file after this fix is silently accepted as "completed," same as today** — accepted to keep this change's scope to the prompt fix + retroactive re-run mechanism; the verification script at least makes the *aggregate* failure rate visible without requiring a pipeline-behavior change.

## Migration Plan

1. Ship the prompt rewrite — affects only files processed from this point forward until step 2 runs.
2. Run `backfill_new_stage.ps1 -NewStageName architecture_spec_writer -EvenIfAlreadyRun` in report-only mode first (no `-Force`) to confirm it targets all 1,578 completed files as expected, then with `-Force` to actually rewind them.
3. Re-run the pipeline (`run_analysis_pipeline_parallel.ps1`) to let workers naturally pick up the now-`queued` files, resuming at `architecture_spec_writer` using each file's already-saved `narrative_writer` intermediate — no re-run of the six upstream analysis stages.
4. Run `verify_synthesis_quality.ps1` before and after to get a real before/after number, not just the qualitative "should be better."

No rollback complexity beyond reverting the prompt text — the resynthesis rewind only affects `last_completed_stage`/`status`, not any already-saved intermediate, so nothing is destructively lost if this needs to be reverted mid-run (a file just resumes from the same point on the next run either way).

## Open Questions

- Exact wording of the anti-echo instruction and the bracketed-placeholder convention — left to implementation, per the same pattern as the narrative-writer change's design (prompt wording is an implementation-time decision, not a spec-level one).
- Whether to also fix `external_library_dependencies`/`database_interactions`'s lighter version of the same pattern in this same pass or a quick separate follow-up — proposal lists it as in-scope-but-secondary; implementation can decide based on how much the primary fix's diff already touches that same prompt block.

**Discovered during implementation, resolved with user:** `templates/source-code-analysis-schema.json`'s top-level `required` list has 16 entries; `$ArchitectureSpecSystemPrompt` has only ever asked for 13 — `source_evidence`, `execution_context`, `interface_contracts`, and `token_usage` are missing entirely, confirmed present in 0 of 1,578 completed files (baseline measurement, task 4.1). This is pre-existing and unrelated to the placeholder-echo bug this change targets — `token_usage` in particular looks like something the orchestration script should inject post-hoc (it's API call metadata, not something the model should invent), not a prompt-content problem at all. Explicitly decided **not** to expand this change's scope to fix it (unmeasured, unresearched relative to the specific 91%/97% numbers that justified this change's scope) — `verify_synthesis_quality.ps1` instead reports it as a separate category so it doesn't make this fix's actual target metrics look unaffected. Filed as a follow-up, same treatment as the unescaped-quote issue.
