# sequential-pipeline-execution Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: One-file-at-a-time stage chain
The pipeline runner SHALL process each queued file through nine agent stages in fixed order (`sanitizer_context_ingestion_agent`, `business_domain_extractor`, `source_ast_structural_mapper`, `business_logic_extractor`, `security_compliance_analyst`, `performance_scalability_analyst`, `test_validation_analyst`, `diagram_designer_context_visualizer`, `architecture_spec_writer`), calling a local Ollama OpenAI-compatible endpoint for each stage, and SHALL feed each stage's output forward as context to later stages according to the documented chain (e.g. the final stage receives domain, structural, logic, security, performance, and test findings).

#### Scenario: Full run on a fresh file
- **WHEN** `run_analysis_pipeline.ps1` processes a file with no prior state
- **THEN** all nine stages run in order, each stage's output is saved as an intermediate, and a final structured report is produced

#### Scenario: -Limit controls batch size
- **WHEN** the script is invoked with `-Limit 5`
- **THEN** at most 5 eligible files are processed in that run, leaving the rest of the queue untouched

#### Scenario: -DryRun shows the plan without calling the model
- **WHEN** the script is invoked with `-DryRun`
- **THEN** it lists which files would be processed and their resume point, and makes no Ollama calls

### Requirement: Resumable per-stage progress
The pipeline runner SHALL persist `last_completed_stage`, per-stage token usage, and intermediate stage output after every completed stage, so an interrupted run resumes from the next incomplete stage instead of restarting the file from scratch.

#### Scenario: Run interrupted mid-file
- **WHEN** a file's state shows `last_completed_stage: business_domain_extractor` from a prior run
- **THEN** the next run for that file skips the sanitizer and business-domain stages, rehydrates their saved intermediate text, and resumes from `source_ast_structural_mapper`

#### Scenario: Retry of a failed final stage
- **WHEN** a file's last completed stage is the final stage (`architecture_spec_writer`) but that attempt produced invalid JSON
- **THEN** the next run retries only that final stage rather than the whole chain

### Requirement: Stall detection and recovery
The pipeline runner SHALL enforce a per-file time budget (`StallMultiplier` times an estimated per-file duration) and, on first exceeding that budget, SHALL unload the model and retry the same file once with an added margin; a second stall on the same file SHALL block it rather than retry indefinitely.

#### Scenario: First stall on a file
- **WHEN** a file's processing time exceeds its budget for the first time
- **THEN** the runner stops/reloads the Ollama model and retries the file with `StallRetryMarginSeconds` of additional budget

#### Scenario: Second stall on the same file
- **WHEN** the retried attempt also exceeds its (margin-extended) budget
- **THEN** the file's state is set to `blocked` with a stall-related error message, its state file is moved to the blocked folder, and processing continues with the next file

### Requirement: Ollama-down recovery
When the Ollama endpoint stops responding (a transient connection error, not a stall), the pipeline runner SHALL wait `OllamaDownWaitSeconds`, restart the Ollama instance, and retry, up to `OllamaDownMaxRetries` times, before blocking the file.

#### Scenario: Ollama connection drops mid-call
- **WHEN** an Ollama call fails with a transient connection error (e.g. connection forcibly closed)
- **THEN** the runner waits, restarts the instance, and retries the same stage, up to the configured retry limit

#### Scenario: Retries exhausted
- **WHEN** the transient-error retry count reaches `OllamaDownMaxRetries` without success
- **THEN** the file is marked `blocked` with an error noting Ollama did not respond after the configured number of restart attempts

### Requirement: Multi-worker queue partitioning
When run with `-WorkerCount` greater than 1, each worker SHALL claim only the subset of eligible files whose relative-path hash modulo `WorkerCount` equals its own `-WorkerIndex`, so that file ownership is invariant regardless of manifest snapshot timing or other files' status changes.

#### Scenario: Two workers on the same queue
- **WHEN** two worker processes are started with `-WorkerCount 2` and `-WorkerIndex 0` / `-WorkerIndex 1` respectively against the same manifest
- **THEN** each file in the queue is claimed by exactly one of the two workers, determined solely by a hash of that file's own path

#### Scenario: Invalid worker index
- **WHEN** the script is invoked with `-WorkerIndex` outside `[0, WorkerCount)`
- **THEN** the script throws and does not process any files

### Requirement: Concurrency-safe manifest updates
Saving progress to the shared `manifest.json` SHALL re-read the current on-disk manifest, splice in only the reporting file's own entry, and serialize the read-modify-write with a cross-process mutex, so that concurrent workers never revert each other's recorded progress; all writes SHALL use atomic write-then-rename.

#### Scenario: Two workers finish files at nearly the same time
- **WHEN** worker A and worker B each finish a different file within the same second and both call Save-Manifest
- **THEN** the resulting manifest.json reflects both workers' updates, with neither entry reverted by the other's write

### Requirement: Process lock registration for external control
Each running pipeline worker SHALL register a lock file under `.analysis-state/locks/<pid>.lock` (recording its PID, worker index/count, and start time) for the duration of the run, and SHALL remove it on exit, so external tooling can discover and safely stop live workers.

#### Scenario: Worker starts and finishes normally
- **WHEN** a worker process starts, runs to completion, and exits
- **THEN** its lock file exists for the duration of the run and is removed once the process exits

### Requirement: Structured final report output
The final stage (`architecture_spec_writer`) SHALL produce a JSON report conforming to the flattened `LegacySourceCodeAnalysisReport` shape; on successful parse, the runner SHALL write the JSON report and (if present) a markdown report and mark the file `completed`; on a parse failure, it SHALL save the raw output, mark the file `blocked`, and record a retry-from-final-stage next action.

#### Scenario: Final stage produces valid JSON
- **WHEN** the architecture-spec-writer stage's output parses as valid JSON
- **THEN** a `<file>.json` report (and `<file>.md` markdown report, if `markdown_report` is present) is written to the file's output directory and the file's status becomes `completed`

#### Scenario: Final stage produces invalid JSON
- **WHEN** the architecture-spec-writer stage's output does not parse as valid JSON
- **THEN** the raw text is saved to `<file>.raw.txt`, the file's status becomes `blocked`, and `next_action` is set to retry from the final stage

