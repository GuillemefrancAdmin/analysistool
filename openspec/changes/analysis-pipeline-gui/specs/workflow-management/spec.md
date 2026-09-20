## ADDED Requirements

### Requirement: Workflow catalog
The system SHALL display a catalog of every defined workflow under `workflows/`, including the built-in `legacy-source-analysis` workflow, showing each workflow's display name, description, and source root(s).

#### Scenario: Opening the workflow catalog
- **WHEN** the operator opens workflow management
- **THEN** the system lists every workflow directory under `workflows/`, including `legacy-source-analysis`, with its display name and description read from its `workflow.json`

### Requirement: Create, clone, rename, and delete a workflow
The system SHALL let the operator create a new empty workflow, clone an existing workflow (copying its stages, prompts, and schema into a new workflow id), rename a workflow's display name/description, and delete a workflow.

#### Scenario: Cloning the built-in workflow as a starting point
- **WHEN** the operator clones `legacy-source-analysis` into a new workflow
- **THEN** the system creates a new `workflows/<new-id>/` directory with copies of the source workflow's `manifest.json`, `skills/`, and `schema.json`, independent of the original

#### Scenario: Deleting a workflow
- **WHEN** the operator deletes a workflow
- **THEN** the system warns that this removes the workflow's definition and, if confirmed, its `.analysis-state/<workflow-id>/` run history, and requires explicit confirmation before proceeding

### Requirement: Configure a workflow's source roots
The system SHALL let the operator view and edit the list of source root(s) a workflow's queue is built from, stored in that workflow's `workflow.json`.

#### Scenario: Adding a second source root
- **WHEN** the operator adds a second source root to a workflow
- **THEN** the system persists both roots in `workflow.json` and the next queue rescan for that workflow discovers files from both

### Requirement: Active workflow selection
The system SHALL let the operator select which workflow the dashboard, stage editor, output browser, and chatbot are currently scoped to, and SHALL make the currently selected workflow visible throughout the application.

#### Scenario: Switching the active workflow
- **WHEN** the operator selects a different workflow from the catalog
- **THEN** the dashboard, stage editor, and output browser update to show that workflow's queue, stages, and outputs

### Requirement: Workflow import and export
The system SHALL let the operator export a workflow's definition (`workflow.json`, `manifest.json`, `skills/`, `schema.json`) to a single portable file, and import such a file as a new workflow.

#### Scenario: Exporting a workflow to share
- **WHEN** the operator exports a workflow
- **THEN** the system produces a single file containing that workflow's definition, excluding any `.analysis-state/<workflow-id>/` run history

#### Scenario: Importing a shared workflow
- **WHEN** the operator imports a previously exported workflow file
- **THEN** the system creates a new `workflows/<workflow-id>/` directory from its contents and adds it to the catalog

### Requirement: Save and load an in-progress workflow draft
The system SHALL hold changes made in the canvas or stage editor as an in-memory draft of the selected workflow, SHALL show an unsaved-changes indicator whenever the draft differs from what is saved on disk, and SHALL let the operator explicitly save the draft (persisting it to `manifest.json`, `layout.json`, `schema.json`, and step `SKILL.md` files) or discard it. Reopening a workflow SHALL load its last-saved definition.

#### Scenario: Unsaved changes indicator
- **WHEN** the operator adds or reorders a step on the canvas without saving
- **THEN** the system shows an unsaved-changes indicator for that workflow until the operator saves or discards the draft

#### Scenario: Discarding a draft
- **WHEN** the operator discards an in-progress draft
- **THEN** the system reverts the canvas and editor to the workflow's last-saved on-disk definition

#### Scenario: Reopening a saved workflow
- **WHEN** the operator closes and reopens a workflow that was previously saved
- **THEN** the system loads the last-saved `manifest.json`/`layout.json`/`schema.json` content, not any discarded draft
