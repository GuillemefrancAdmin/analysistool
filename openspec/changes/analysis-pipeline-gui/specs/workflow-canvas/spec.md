## ADDED Requirements

### Requirement: Visual workflow graph
The system SHALL display the selected workflow's stages and their steps as connected nodes on a drawing pane, reflecting the order recorded in `manifest.json` and the positions recorded in `layout.json`.

#### Scenario: Opening the canvas for a workflow
- **WHEN** the operator opens the canvas for a workflow
- **THEN** the system draws a node for each stage containing its steps, connected in execution order, positioned per that workflow's `layout.json`

### Requirement: Add, remove, and reorder nodes on the canvas
The system SHALL let the operator add a new stage or step, remove an existing one, and reorder stages and steps directly on the canvas, persisting the change to `manifest.json`.

#### Scenario: Adding a step to a stage from the canvas
- **WHEN** the operator adds a new step to an existing stage on the canvas
- **THEN** the system creates the corresponding `SKILL.md` and manifest entry and shows the new step as a node within that stage

#### Scenario: Reordering steps within a stage
- **WHEN** the operator drags a step to a new position within its stage
- **THEN** the system persists the new step order to `manifest.json` and subsequent runs execute that stage's steps in the new order

### Requirement: Node selection opens detail editing
The system SHALL let the operator select a node on the canvas to open that stage's or step's detail editor (structured form or raw Markdown, per the stage definition editor).

#### Scenario: Selecting a step node
- **WHEN** the operator selects a step node on the canvas
- **THEN** the system opens that step's structured `SKILL.md` editor

### Requirement: Layout persisted separately from execution data
The system SHALL persist canvas node positions to the workflow's `layout.json` and SHALL NOT write position/layout data into `manifest.json`.

#### Scenario: Moving a node without changing structure
- **WHEN** the operator drags a node to a new position without adding, removing, or reordering anything
- **THEN** the system updates only `layout.json`, leaving `manifest.json` byte-for-byte unchanged

### Requirement: Sequential step execution indicator
The system SHALL visually indicate that steps within a stage execute strictly in the order shown, with no branching or parallel paths supported in the current version.

#### Scenario: Operator attempts to create a branch
- **WHEN** the operator tries to connect a step to more than one following step within the same stage
- **THEN** the system does not allow the branching connection and indicates that steps run sequentially in this version
