## MODIFIED Requirements

### Requirement: One state file per source file
Each discovered source file SHALL have exactly one corresponding state file named `<source-file-stem>.<ext>.state.json` (or hash-disambiguated per `source-discovery-queue`), recording `source_path`, `status`, `analysis_type`, `last_completed_stage`, `updated_at`, `blocker_or_error`, `next_action`, `output_references`, and per-agent `token_usage`.

#### Scenario: State file fields present after any update
- **WHEN** a file's state is saved after any pipeline stage
- **THEN** the state file contains all of `source_path`, `status`, `last_completed_stage`, `updated_at`, `blocker_or_error`, `next_action`, `output_references`, and `token_usage.agents.<agent_name>` entries for every one of the eleven agent names

### Requirement: Output artifacts kept self-contained per file
Generated outputs for a file (sanitized/intermediate stage text, the final JSON report, a markdown narrative, and a diagram file) SHALL be written under `.analysis-state/outputs/<sanitized-relative-dir>/`, alongside a copy of the original source file, so each output folder is readable without the source tree present. The markdown narrative is the `narrative_writer` stage's own independent output artifact, not a field embedded in the JSON report.

#### Scenario: Output folder contents after completion
- **WHEN** a file completes analysis
- **THEN** its output folder contains a copy of the original source file, an `intermediates/` folder with each stage's saved text, the final `<file>.json` report, and (if that stage itself completed) `<file>.md` and `diagram.mmd`
