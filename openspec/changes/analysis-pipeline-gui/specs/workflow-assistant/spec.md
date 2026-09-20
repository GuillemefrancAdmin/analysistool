## ADDED Requirements

### Requirement: Mandatory first-run LLM configuration
The system SHALL require the operator to configure a local LLM connection (endpoint URL and model) before workflow management, the dashboard, stage editor, or output browser become accessible, and SHALL present this configuration step automatically on first launch or whenever no working connection is on record.

#### Scenario: Launching the app with no LLM configured
- **WHEN** the operator launches the app and `.analysis-state/app-config.json` has no configured LLM endpoint/model
- **THEN** the system opens the LLM setup wizard and does not allow navigation to workflow management, the dashboard, stage editor, or output browser until setup completes

#### Scenario: Reconfiguring the connection later
- **WHEN** the operator opens Settings after initial setup
- **THEN** the system lets them view and change the configured LLM endpoint and model, reusing the same wizard

### Requirement: LLM connection validation
The system SHALL test the configured endpoint and model with a live connection check before accepting the setup wizard's input, and SHALL show a clear success or failure result.

#### Scenario: Endpoint unreachable
- **WHEN** the operator submits an endpoint URL that does not respond during the wizard's connection test
- **THEN** the system reports the failure with the URL and error that was attempted, and does not mark setup as complete

#### Scenario: Successful test
- **WHEN** the configured endpoint responds successfully to the test call
- **THEN** the system marks the LLM connection as configured, persists it to `.analysis-state/app-config.json`, and unlocks the rest of the application

### Requirement: In-app workflow assistant chatbot
The system SHALL provide a persistent chatbot panel, backed by the configured local LLM, available from workflow management, the dashboard, and the stage definition editor, that the operator can use to ask questions about and get help designing and running workflows.

#### Scenario: Asking the assistant about the selected workflow
- **WHEN** the operator asks the chatbot a question about the selected workflow's stage list or a specific stage's role
- **THEN** the assistant answers using the current contents of that workflow's `manifest.json` and the relevant `SKILL.md` file

### Requirement: Context-grounded assistance
The system SHALL give the chatbot read access to the workflow catalog (`workflows/**`), the selected workflow's `manifest.json`, its step `SKILL.md` files, its `schema.json` (including node-to-step mappings), its `layout.json`, `.analysis-state/app-config.json`, and current run state across workflows, so its answers and actions reflect the application's actual current state.

#### Scenario: Assistant suggestion reflects current stages
- **WHEN** the operator asks the assistant to suggest a new stage for the selected workflow
- **THEN** the suggestion accounts for that workflow's existing stage order and content rather than being generated without that context

### Requirement: Drafting a new workflow from a description
The system SHALL let the chatbot draft a complete new workflow — an ordered stage list with prompts, an output schema, and a suggested source root — from a natural-language description of the task the operator wants performed, and create it as a new entry in the workflow catalog.

#### Scenario: Operator describes a new kind of analysis
- **WHEN** the operator describes a workflow the chatbot has no existing definition for (e.g. "generate a security audit report for each file")
- **THEN** the chatbot drafts a new `workflows/<workflow-id>/` definition (stages, prompts, schema, suggested source root) and adds it to the workflow catalog as a new, independent workflow

### Requirement: Full workflow and run control
The system SHALL let the chatbot read and write, on the operator's behalf, everything the operator can reach through the UI: the workflow catalog (create/clone/rename/delete), a workflow's `manifest.json`, its step `SKILL.md` files, its `schema.json` and node-to-step mappings, its `layout.json`, its source root configuration, `.analysis-state/app-config.json` settings, and run control (start/pause/resume/stop/reset) for any workflow.

#### Scenario: Chatbot applies a low-risk stage edit directly
- **WHEN** the operator asks the chatbot to update a stage's Responsibilities section for the selected workflow and the change does not match any high-risk category
- **THEN** the system applies the change immediately through the structured stage editor's save path, including its existing validation, without requiring a separate approval step

#### Scenario: Chatbot starts a run
- **WHEN** the operator asks the chatbot to start processing a workflow's queue
- **THEN** the system starts that workflow's run through the same control path as the dashboard's Start action

### Requirement: Confirmation required for high-risk actions
The system SHALL pause and require the operator's explicit confirmation before the chatbot: removes a stage that has already-recorded completions in existing state files, deletes an entire workflow, resets the entire queue for a workflow, stops or resets a currently active run, or changes the configured LLM connection away from one that is currently working. The system SHALL NOT perform any of these actions without that confirmation.

#### Scenario: Chatbot asked to remove an in-use stage
- **WHEN** the operator asks the chatbot to remove a stage that has completed entries in a workflow's existing state files
- **THEN** the system describes what will be affected and asks the operator to confirm before removing the stage from that workflow's `manifest.json`

#### Scenario: Chatbot asked to delete a workflow
- **WHEN** the operator asks the chatbot to delete a workflow
- **THEN** the system describes what will be removed (the workflow's definition and, if applicable, its run history) and asks the operator to confirm before deleting the `workflows/<workflow-id>/` directory

#### Scenario: Chatbot asked to reset a workflow's whole queue
- **WHEN** the operator asks the chatbot to reset a workflow's entire queue
- **THEN** the system asks for explicit confirmation, describing the progress that will be lost, before clearing any queue state

#### Scenario: Operator declines confirmation
- **WHEN** the operator declines a high-risk action the chatbot asked to confirm
- **THEN** the system takes no action and leaves the on-disk files and run state unchanged

### Requirement: Validation floor regardless of risk tier
The system SHALL reject any chatbot-initiated write that fails the same validation applied to manual edits (e.g. invalid JSON Schema, malformed manifest), whether or not the action required confirmation, and SHALL report the validation error back to the operator instead of applying it.

#### Scenario: Chatbot writes an invalid schema
- **WHEN** a chatbot-initiated schema edit for a workflow is not valid JSON Schema
- **THEN** the system rejects the write, leaves that workflow's `schema.json` unchanged, and reports the validation error to the operator

### Requirement: Chatbot action logging
The system SHALL record every chatbot-initiated write, whether auto-applied or confirmed, in an audit trail distinguishable from manually-made edits, so the operator can review what the assistant changed.

#### Scenario: Reviewing recent chatbot activity
- **WHEN** the operator opens the chatbot's action log
- **THEN** the system lists recent chatbot-initiated changes with what changed, when it happened, which workflow it affected, and whether it was auto-applied or required confirmation

### Requirement: PowerShell script authoring and execution
The system SHALL let the chatbot draft a PowerShell script to carry out an operator-requested workflow task and execute it on the operator's behalf, always showing the script's content and its result (stdout, stderr, exit code) in the chat. Scripts are ad hoc workflow automation the operator requests; they are not a mechanism for running any workflow's stages, which remains the exclusive responsibility of the native pipeline engine.

#### Scenario: Operator asks for a bulk cleanup task
- **WHEN** the operator asks the chatbot to reset all failed files matching a name pattern within the selected workflow
- **THEN** the chatbot drafts a script to perform that update, shows it, and, if it stays within the default execution scope, runs it and reports the result

### Requirement: Default script execution scope
The system SHALL execute chatbot-authored scripts, by default, only against the currently selected workflow's managed directories (`workflows/<workflow-id>/`, `.analysis-state/<workflow-id>/`), `.analysis-state/app-config.json`, and an app-defined scratch directory, and SHALL NOT permit them to read or write any workflow's source root(s), another workflow's directories, or make network calls within that default scope.

#### Scenario: Script attempts to touch a source root
- **WHEN** a chatbot-drafted script would modify a file under a workflow's configured source root
- **THEN** the system does not execute it within the default scope and instead treats it as high-risk per the confirmation requirement

### Requirement: High-risk script confirmation
The system SHALL treat a chatbot-authored script as high-risk — requiring the same explicit operator confirmation as other high-risk actions — whenever it would touch a path outside the default execution scope, delete or overwrite files, or perform a system/process-level change, and SHALL NOT execute it without that confirmation.

#### Scenario: Script deletes files
- **WHEN** a chatbot-drafted script includes a delete or overwrite operation
- **THEN** the system shows the script and asks the operator to confirm before running it

#### Scenario: Operator declines a high-risk script
- **WHEN** the operator declines to confirm a high-risk script
- **THEN** the system does not execute it and leaves the filesystem unchanged

### Requirement: Script execution logging
The system SHALL record every chatbot-executed script — its content, execution time, captured stdout/stderr, and exit code — in the same chatbot action log used for other chatbot-initiated actions.

#### Scenario: Reviewing a past script run
- **WHEN** the operator opens the chatbot's action log after a script has run
- **THEN** the system shows the script's full content and its captured output alongside other logged chatbot actions
