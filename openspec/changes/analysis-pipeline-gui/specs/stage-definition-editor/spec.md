## ADDED Requirements

### Requirement: Ordered stage and step list view
The system SHALL display the selected workflow's stages in execution order, sourced from `workflows/<workflow-id>/manifest.json`, and, for each stage, its steps in execution order, showing each stage's and step's id, display name, and the `skills/<stage-id>/<step-id>/SKILL.md` file it edits.

#### Scenario: Viewing the current workflow's stages and steps
- **WHEN** the operator opens the stage editor for a workflow
- **THEN** the system lists all of that workflow's stages in the order recorded in its `manifest.json`, each showing its steps in their recorded order

### Requirement: Reorder, add, and remove stages and steps
The system SHALL let the operator reorder a workflow's stages and, within a stage, its steps; add a new stage or a new step to an existing stage (creating a new `workflows/<workflow-id>/skills/<stage-id>/<step-id>/SKILL.md` and manifest entry); and remove a stage or a step, updating that workflow's `manifest.json` accordingly.

#### Scenario: Reordering two stages
- **WHEN** the operator moves a stage earlier or later in a workflow's list and saves
- **THEN** the system persists the new order to that workflow's `manifest.json` and subsequent runs of that workflow execute stages in the new order

#### Scenario: Adding a second step to a stage
- **WHEN** the operator adds a new step to a stage that currently has one step
- **THEN** the system creates the new step's `SKILL.md` and manifest entry, and subsequent runs execute that stage's steps in their defined order

#### Scenario: Removing a stage or step in use
- **WHEN** the operator removes a stage or step that has already-recorded completions in that workflow's existing state files
- **THEN** the system warns that removing it does not retroactively alter already-completed state files, and requires confirmation before proceeding

### Requirement: Structured step content editing
The system SHALL parse a step's `SKILL.md` into its standard sections (Role, Mission, Inputs, Responsibilities, Workflow, Expected output, Quality rules) and present them as editable form fields, writing changes back to the file's Markdown on save.

#### Scenario: Editing a well-formed step file
- **WHEN** the operator edits the "Responsibilities" field of a step whose `SKILL.md` matches the standard section headings and saves
- **THEN** the system writes the updated content back under the same heading, leaving other sections unchanged

### Requirement: Raw Markdown fallback
The system SHALL provide a raw Markdown editing view for any step file, usable when a file's structure doesn't match the standard sections or when the operator prefers direct editing.

#### Scenario: Step file with non-standard structure
- **WHEN** a `SKILL.md` file does not match the expected section headings
- **THEN** the system opens it in the raw Markdown view instead of the structured form, without data loss

### Requirement: Per-step model parameter configuration
The system SHALL let the operator configure per-step overrides (model name, temperature, timeout) stored in the workflow's `manifest.json`, falling back to that step's stage, then the workflow's own defaults (`workflow.json`), then the app-wide defaults (`app-config.json`) when unset.

#### Scenario: Overriding a single step's model
- **WHEN** the operator sets a specific model for one step and leaves other steps unset
- **THEN** the pipeline engine uses that model only for the overridden step and the stage's (or workflow's, or app-wide) default model for all other steps
