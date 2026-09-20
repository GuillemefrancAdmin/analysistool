## ADDED Requirements

### Requirement: Workflow switcher
The system SHALL let the operator switch between defined workflows from the dashboard, and SHALL show which workflows currently have an active run, not only the selected one.

#### Scenario: Switching workflows on the dashboard
- **WHEN** the operator selects a different workflow from the dashboard's workflow switcher
- **THEN** the dashboard's queue, checkpoint, token usage, and run-control views update to reflect that workflow

#### Scenario: Multiple workflows running unattended
- **WHEN** two workflows both have active runs
- **THEN** the dashboard indicates both are running, even while only one is the currently selected workflow

### Requirement: Queue and file status view
The system SHALL display the selected workflow's current queue with, for each file, its path, status, last completed stage, and last updated time, refreshed automatically as that workflow's `.analysis-state/<workflow-id>/queue` and `.analysis-state/<workflow-id>/states` change on disk.

#### Scenario: Status changes during a live run
- **WHEN** a running worker updates a file's state JSON for the selected workflow
- **THEN** the dashboard reflects the new status and last-completed-stage within a few seconds, without requiring a manual refresh

### Requirement: Step-level progress within a stage
The system SHALL show which step of the current stage a file is on when that stage has more than one step, in addition to the file's current stage.

#### Scenario: A file is mid-stage with multiple steps
- **WHEN** a file is being processed by a stage that has more than one step
- **THEN** the dashboard shows both the current stage and the current step within it

### Requirement: Checkpoint and progress history view
The system SHALL display the selected workflow's checkpoint history (progress totals: completed, in-progress, queued, blocked, failed) and let the operator inspect an individual checkpoint's recorded state.

#### Scenario: Operator inspects a past checkpoint
- **WHEN** the operator selects a checkpoint from the history list for the selected workflow
- **THEN** the dashboard shows that checkpoint's recorded queue progress and last-processed-file details

### Requirement: Token usage and ETA reporting
The system SHALL show per-file and run-total token usage per stage for the selected workflow, and an estimated time to completion for its remaining queue based on observed per-file processing time.

#### Scenario: Mid-run ETA
- **WHEN** at least one file has completed during the selected workflow's current run
- **THEN** the dashboard shows an ETA for that workflow's remaining queued files derived from the average completed-file duration

### Requirement: Run control actions
The system SHALL expose start, pause, resume, stop, and reset actions for the selected workflow's run, reflecting its current run state (e.g. disabling "pause" when no run is active for that workflow).

#### Scenario: Start with no run active
- **WHEN** no run is currently active for the selected workflow and the operator clicks "Start"
- **THEN** the system begins processing that workflow's queue and updates the dashboard's run-state indicator to "running"

#### Scenario: Stop mid-run
- **WHEN** a run is active for the selected workflow and the operator clicks "Stop"
- **THEN** the system halts all of that workflow's workers after their current in-flight stage completes and updates the run-state indicator to "stopped"

### Requirement: Blocked/failed file surfacing
The system SHALL prominently list files currently in `blocked` or `failed` status within the selected workflow along with their recorded error, and let the operator retry or reset them directly from that list.

#### Scenario: Operator retries a blocked file
- **WHEN** the operator selects a blocked file from the selected workflow's blocked-files list and clicks "Retry"
- **THEN** the system clears the blocker and re-queues the file from its last completed stage
