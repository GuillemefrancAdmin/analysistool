## MODIFIED Requirements

### Requirement: One state file per source file
Each discovered source file SHALL have exactly one corresponding state file named `<source-file-stem>.<ext>.state.json` (or hash-disambiguated per `source-discovery-queue`), recording `source_path`, `status`, `analysis_type`, `last_completed_stage`, `updated_at`, `blocker_or_error`, `next_action`, `output_references`, and per-agent `token_usage`.

#### Scenario: State file fields present after any update
- **WHEN** a file's state is saved after any pipeline stage
- **THEN** the state file contains all of `source_path`, `status`, `last_completed_stage`, `updated_at`, `blocker_or_error`, `next_action`, `output_references`, and a `token_usage.agents.<agent_name>` entry for every agent name in the shared stage registry's full roster (see `pipeline-stage-registry`), each built from the one canonical empty-agent-usage template
