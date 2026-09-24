# analysis-state-persistence Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: State kept outside the source tree
All queue, per-file progress, checkpoint, lock, and output metadata SHALL live under `.analysis-state/`, kept separate from the analyzed source tree, so the workflow can manage its own operational state without modifying or polluting `source code/`, `Processus affaires/`, or `documentation/`.

#### Scenario: Directory layout
- **WHEN** `.analysis-state/` is inspected
- **THEN** it contains `queue/`, `states/`, `checkpoints/`, `outputs/`, and `locks/` subdirectories, and no files under the analyzed source directories are modified by the pipeline

### Requirement: One state file per source file
Each discovered source file SHALL have exactly one corresponding state file named `<source-file-stem>.<ext>.state.json` (or hash-disambiguated per `source-discovery-queue`), recording `source_path`, `status`, `analysis_type`, `last_completed_stage`, `updated_at`, `blocker_or_error`, `next_action`, `output_references`, and per-agent `token_usage`.

#### Scenario: State file fields present after any update
- **WHEN** a file's state is saved after any pipeline stage
- **THEN** the state file contains all of `source_path`, `status`, `last_completed_stage`, `updated_at`, `blocker_or_error`, `next_action`, `output_references`, and a `token_usage.agents.<agent_name>` entry for every agent name in the shared stage registry's full roster (see `pipeline-stage-registry`), each built from the one canonical empty-agent-usage template

### Requirement: Status-based state file relocation
A file's state record SHALL be relocated from `states/` into a status-specific subfolder — `states/done/` on completion, `states/blocked/` on blocking — so the top-level `states/` folder reflects only files still in flight; the manifest's `state_file` reference SHALL be updated to match.

#### Scenario: File completes analysis
- **WHEN** a file's status transitions to `completed`
- **THEN** its state file is moved to `states/done/` and the manifest's `state_file` path for that entry is updated to point there

#### Scenario: File is blocked
- **WHEN** a file's status transitions to `blocked`
- **THEN** its state file is moved to `states/blocked/` and the manifest's `state_file` path is updated to point there

### Requirement: Checkpoint recorded per file completion or block
A checkpoint file named `<timestamp>-checkpoint.json` SHALL be written after each file finishes processing (whether completed or blocked), recording `checkpoint_id`, `created_at`, `run_id`, `last_processed_file` (path, state file, last completed stage, status), `queue_progress` totals, and `next_action`, so a run can be resumed without rescanning every state file.

#### Scenario: Checkpoint after a completed file
- **WHEN** a file finishes with status `completed`
- **THEN** a new checkpoint file is written recording that file as `last_processed_file` with status `completed` and updated `queue_progress` counts

### Requirement: Output artifacts kept self-contained per file
Generated outputs for a file (sanitized/intermediate stage text, the final JSON report, a markdown narrative, and a diagram file) SHALL be written under `.analysis-state/outputs/<sanitized-relative-dir>/`, alongside a copy of the original source file, so each output folder is readable without the source tree present. The markdown narrative is the `narrative_writer` stage's own independent output artifact, not a field embedded in the JSON report.

#### Scenario: Output folder contents after completion
- **WHEN** a file completes analysis
- **THEN** its output folder contains a copy of the original source file, an `intermediates/` folder with each stage's saved text, the final `<file>.json` report, and (if that stage itself completed) `<file>.md` and `diagram.mmd`

### Requirement: Manifest is the live, mutable index
`.analysis-state/queue/manifest.json` SHALL be the single mutable index of all tracked files and their status, safe for concurrent read by reporting tools (`queue_eta.ps1`) and concurrent read-modify-write by multiple pipeline workers, via the write safety and locking behavior defined in `source-discovery-queue` and `sequential-pipeline-execution`. Readers of the manifest SHALL additionally attempt to auto-repair known, narrow corruption patterns before falling back to their existing retry/failure behavior: first, a small number of non-ASCII characters appearing in raw JSON structural whitespace (since the manifest's own content is always plain ASCII, any such character is reliably corruption); and if that doesn't apply or doesn't succeed, a bounded search for a single-bit-flip-plausible character substitution near the parse failure's reported location.

#### Scenario: Manifest reflects current queue state at any time
- **WHEN** the manifest is read at any point during or between runs
- **THEN** it lists every discovered file with its current `status`, `last_completed_stage`, and `token_usage`, consistent with each file's own state file

#### Scenario: A known stray-character corruption is repaired transparently
- **WHEN** a manifest read fails to parse as JSON, and the raw content contains five or fewer characters outside the normal ASCII range
- **THEN** the reader replaces those characters and retries parsing once before falling back to its normal retry/failure behavior, and if the repaired content parses successfully, the read succeeds using the repaired content without the caller needing to handle the failure

#### Scenario: A single-bit-flip-style character substitution is repaired transparently
- **WHEN** a manifest read fails to parse as JSON, the non-ASCII repair doesn't apply or doesn't succeed, and a bounded search near the parse failure's reported location finds a single-bit-flip variant of some nearby character that makes the entire document parse successfully
- **THEN** the reader uses that repaired content, within a bounded number of search attempts, without the caller needing to handle the failure

#### Scenario: An unfamiliar or larger-scale corruption is not silently guessed at
- **WHEN** a manifest read fails to parse as JSON, and neither the non-ASCII repair nor the bounded bit-flip search (within its attempt budget) produces content that parses successfully
- **THEN** the reader does not accept a guessed repair, and falls through to its existing retry-then-throw behavior instead

