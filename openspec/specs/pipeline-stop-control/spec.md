# pipeline-stop-control Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: Discover live workers via lock files
The stop script SHALL scan `.analysis-state/locks/*.lock`, verify each recorded PID actually corresponds to a running process, and SHALL treat only those as live; locks whose process is no longer running SHALL be removed as stale without further action.

#### Scenario: No lock files present
- **WHEN** `.analysis-state/locks/` contains no lock files
- **THEN** the script reports no running pipeline process found and exits without prompting

#### Scenario: Lock file for a dead process
- **WHEN** a lock file's PID does not correspond to any running process
- **THEN** the lock file is deleted and that entry is not counted as a live worker

### Requirement: Stop without touching state or output
The stop script SHALL terminate only the live worker processes it finds and remove their lock files; it SHALL NOT modify, move, or delete any state file, output file, checkpoint, or the manifest.

#### Scenario: Stop a live worker mid-file
- **WHEN** the script terminates a live worker process
- **THEN** that file's current state record, any output already written, and `manifest.json` are left exactly as they were at termination, unmodified by this script

### Requirement: Confirmation before termination
The stop script SHALL prompt for explicit `yes` confirmation before terminating any process, unless invoked with `-Force`.

#### Scenario: Interactive stop without -Force
- **WHEN** the script finds live workers and is run without `-Force`
- **THEN** it lists their PIDs and only terminates them if the user types `yes`

#### Scenario: -Force skips the prompt
- **WHEN** the script is run with `-Force`
- **THEN** all discovered live workers are terminated immediately without prompting

