# analysis-state-reset Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: Scope limited to generated artifacts
The reset script SHALL delete only generated artifacts under `.analysis-state` — state files under `states/` (excluding `README.md`), files under `checkpoints/`, files under `outputs/`, and `queue/manifest.json` — and SHALL leave hand-written docs and everything outside `.analysis-state` untouched.

#### Scenario: Reset run in a populated state directory
- **WHEN** the reset script runs against a `.analysis-state` directory containing state files, checkpoints, outputs, and a manifest
- **THEN** all of those are deleted while `.analysis-state/README.md` and any files under `skills/`, `templates/`, or `source code/` remain untouched

### Requirement: Live workers are stopped before deletion
Before deleting any files, the reset script SHALL detect currently-running pipeline workers via their lock files under `.analysis-state/locks/`, and SHALL terminate any still-live process (and remove its lock) so state/output files are never deleted out from under an active run; stale locks (process no longer running) SHALL simply be cleaned up.

#### Scenario: A worker is actively running
- **WHEN** the reset script finds a lock file whose PID corresponds to a live process
- **THEN** that process is terminated and its lock file removed before any state/output deletion proceeds

#### Scenario: A stale lock from a crashed worker
- **WHEN** a lock file's PID no longer corresponds to any running process
- **THEN** the lock file is removed without attempting to stop any process

### Requirement: Confirmation before destructive action
The reset script SHALL prompt for explicit `yes` confirmation before deleting anything, unless invoked with `-Force`, and SHALL report the exact counts of files/processes that will be affected before that prompt.

#### Scenario: Interactive run without -Force
- **WHEN** the script is run without `-Force`
- **THEN** it lists the counts of state files, checkpoints, outputs, and any live processes to be terminated, and only proceeds if the user types `yes`

#### Scenario: Non-'yes' response aborts
- **WHEN** the user responds with anything other than `yes`
- **THEN** the script aborts and deletes nothing

#### Scenario: -Force skips the prompt
- **WHEN** the script is run with `-Force`
- **THEN** deletion proceeds immediately without prompting

### Requirement: Already-clean state is a no-op
When there are no state files, checkpoints, outputs, or manifest, and no live workers, the reset script SHALL report that there is nothing to clean and exit without prompting.

#### Scenario: Reset run on an already-reset directory
- **WHEN** the reset script runs against a `.analysis-state` directory with no generated artifacts and no live locks
- **THEN** it prints that nothing needs cleaning and exits successfully without asking for confirmation

### Requirement: Optional queue regeneration
The reset script SHALL support `-Regenerate`, which, after a successful cleanup, invokes the queue generator to rebuild `manifest.json` and fresh per-file state records.

#### Scenario: Reset with regeneration
- **WHEN** the script is run with `-Force -Regenerate`
- **THEN** after cleanup completes, `generate_analysis_queue.ps1` is invoked automatically to rebuild the queue

#### Scenario: Reset without regeneration
- **WHEN** the script is run with `-Force` and no `-Regenerate`
- **THEN** cleanup completes and the script reports that the queue was not regenerated, leaving that as a separate manual step

