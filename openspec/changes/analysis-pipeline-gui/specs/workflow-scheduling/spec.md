## ADDED Requirements

### Requirement: Schedule a workflow run
The system SHALL let the operator schedule a run of a selected workflow with a start date/time and, optionally, a recurrence, by registering a native Windows Scheduled Task.

#### Scenario: Scheduling a one-time run
- **WHEN** the operator schedules a workflow to start at a specific future date and time
- **THEN** the system creates a Windows Scheduled Task with a matching one-time trigger that launches the app in headless mode targeting that workflow

#### Scenario: Scheduling a recurring run
- **WHEN** the operator schedules a workflow to run on a recurring basis (e.g. daily)
- **THEN** the system creates a Windows Scheduled Task with a matching recurring trigger

### Requirement: Maximum run time
The system SHALL let the operator set a maximum run time for a scheduled run, enforced via the scheduled task's native execution time limit rather than custom in-app timing logic.

#### Scenario: Run exceeds its maximum time
- **WHEN** a scheduled run exceeds the configured maximum run time
- **THEN** Windows stops the task per its execution time limit, and the app's next launch (scheduled or manual) shows the run as stopped/incomplete rather than still "running"

### Requirement: Retry on failure
The system SHALL let the operator set a retry count and retry interval for a scheduled run, enforced via the scheduled task's native restart-on-failure settings.

#### Scenario: Scheduled run fails to start
- **WHEN** a scheduled run fails (e.g. the configured LLM endpoint is unreachable) and a retry count is configured
- **THEN** Windows retries the task at the configured interval up to the configured count, per the task's native restart settings

### Requirement: Manage scheduled runs from within the app
The system SHALL let the operator view, edit, and delete scheduled runs for any workflow without leaving the application.

#### Scenario: Viewing all scheduled runs
- **WHEN** the operator opens the scheduling view
- **THEN** the system lists every scheduled task the app has created, showing its target workflow, next run time, recurrence, max run time, and retry settings

#### Scenario: Deleting a schedule
- **WHEN** the operator deletes a scheduled run
- **THEN** the system removes the corresponding Windows Scheduled Task

### Requirement: Headless launch mode
The system SHALL support launching without displaying a window when invoked with a headless/unattended command-line flag identifying a target workflow, running that workflow to completion, a stop, or its time limit, then exiting.

#### Scenario: Scheduled trigger fires with the app not running
- **WHEN** a scheduled task's trigger fires and no instance of the app is currently running
- **THEN** the system starts a new instance in headless mode, runs the target workflow, and exits without showing a window

### Requirement: Single-instance handoff
The system SHALL detect an already-running instance of the app before starting a headless run, and SHALL hand off the run request to that instance instead of starting a duplicate process.

#### Scenario: Scheduled trigger fires while the app is already open
- **WHEN** a scheduled task's trigger fires and the app is already running (GUI open)
- **THEN** the system sends the run request to the running instance, which starts the target workflow's run, and no second process or window is created

### Requirement: Scheduled runs visible alongside manual runs
The system SHALL record a scheduled run's start, completion, and outcome the same way a manually started run is recorded, visible in the dashboard and, if chatbot-initiated, the chatbot action log.

#### Scenario: Reviewing a scheduled run's history
- **WHEN** the operator opens the dashboard for a workflow that had a scheduled run overnight
- **THEN** the dashboard shows that run's progress and outcome the same as it would for a manually started run
