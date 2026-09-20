## ADDED Requirements

### Requirement: Native queue discovery per workflow
The system SHALL discover analysis-eligible files under a workflow's configured source root(s) and write/update `.analysis-state/<workflow-id>/queue/manifest.json` and one `.analysis-state/<workflow-id>/states/<file>.state.json` per discovered file, without invoking any PowerShell script.

#### Scenario: New files added to a workflow's source root
- **WHEN** the operator triggers a queue rescan for a workflow and new files exist under its source root(s) that are not yet in `.analysis-state/<workflow-id>/queue/manifest.json`
- **THEN** the system adds queue entries and state files for the new files with status `queued`, leaving existing entries for already-known files unchanged

#### Scenario: Rescan preserves in-progress work
- **WHEN** a rescan runs for a workflow while a file's state is `in_progress` or `completed`
- **THEN** the system leaves that file's status, `last_completed_stage`, and `state_file` contents unchanged

### Requirement: One-file-at-a-time stage execution
The system SHALL process a queued file through its workflow's ordered stages one at a time per worker, calling the configured Ollama-compatible endpoint for each stage (resolving model/temperature/timeout per the stage → workflow → app-wide override chain), and SHALL persist per-stage progress to the file's state JSON after every completed stage.

#### Scenario: Successful stage completion
- **WHEN** a stage call for a queued file returns a successful result
- **THEN** the system updates `last_completed_stage`, `updated_at`, `token_usage`, and `output_references` in the file's state JSON before starting the next stage

#### Scenario: Stage failure
- **WHEN** a stage call fails or returns an error
- **THEN** the system records the error in `blocker_or_error`, sets the file's status to `blocked` or `failed` as appropriate, and does not advance `last_completed_stage`

### Requirement: Sequential step execution within a stage
The system SHALL execute a stage's steps one at a time, in the order recorded in `manifest.json`, resolving each step's model/temperature/timeout per the step → stage → workflow → app-wide override chain, and SHALL persist per-step progress to the file's state JSON after every completed step.

#### Scenario: A stage with multiple steps
- **WHEN** a queued file reaches a stage that has more than one step
- **THEN** the system runs that stage's steps in their defined order, one at a time, before advancing `last_completed_stage` to the next stage

#### Scenario: A step within a stage fails
- **WHEN** one of a stage's steps fails or returns an error
- **THEN** the system records the error in `blocker_or_error`, sets the file's status to `blocked` or `failed`, and does not advance past that step

### Requirement: Multi-worker partitioning within a workflow
The system SHALL support running multiple concurrent workers against the same workflow's queue, each bound to a configured endpoint, such that each queued file is claimed and processed by exactly one worker at a time.

#### Scenario: Two workers active on the same workflow's queue
- **WHEN** two workers are running concurrently against the same workflow's `.analysis-state/<workflow-id>/queue`
- **THEN** each eligible queued file is claimed by exactly one worker, using `.analysis-state/<workflow-id>/locks` to prevent double-claiming

### Requirement: Isolation between concurrently running workflows
The system SHALL keep each workflow's queue, state, locks, and checkpoints isolated under its own `.analysis-state/<workflow-id>/` directory, such that running one workflow does not read, modify, or claim files belonging to another workflow's queue, and SHALL allow more than one workflow to have an active run at the same time.

#### Scenario: Two workflows running at once
- **WHEN** the operator starts runs for two different workflows at the same time
- **THEN** each workflow's workers only claim and process files from that workflow's own queue, and each workflow's state/checkpoint files are written only under that workflow's own `.analysis-state/<workflow-id>/` directory

### Requirement: Stall detection and retry
The system SHALL detect a file whose current stage exceeds its configured time budget, treat it as stalled, and retry it once with an extended budget before marking it blocked.

#### Scenario: Stage exceeds budget once
- **WHEN** a stage's elapsed time exceeds the worker's stall budget for the first time on a given file
- **THEN** the system aborts the in-flight call, retries the same stage once with the configured retry margin added to the budget

#### Scenario: Stage stalls twice
- **WHEN** the retried stage also exceeds its budget
- **THEN** the system marks the file `blocked` with a stall reason recorded in `blocker_or_error` and moves to the next eligible file

### Requirement: Checkpointing and resume
The system SHALL write a checkpoint after each completed file within a workflow and SHALL be able to resume that workflow's run from its latest checkpoint without reprocessing already-completed stages.

#### Scenario: Run interrupted and restarted
- **WHEN** the application is closed or crashes mid-run and later restarted
- **THEN** the system resumes each workflow that had an active run from its latest `.analysis-state/<workflow-id>/checkpoints/*.json` and continues with queued/in-progress files, skipping stages already recorded as completed

### Requirement: Run lifecycle control
The system SHALL let the operator start, pause, resume, stop, and reset (a single file or the entire queue) a run for any given workflow from the application, with no PowerShell invocation required.

#### Scenario: Operator pauses a run
- **WHEN** the operator issues a pause action for a workflow while its workers are active
- **THEN** the system lets any in-flight stage call finish, then halts starting new stage calls for that workflow until resumed

#### Scenario: Operator resets a single file
- **WHEN** the operator selects a file within a workflow and issues a reset action
- **THEN** the system clears that file's `last_completed_stage`, `blocker_or_error`, and `output_references`, and sets its status back to `queued`, leaving other files and other workflows unaffected
