## ADDED Requirements

### Requirement: Structured schema tree view
The system SHALL let the operator view and edit the selected workflow's `schema.json` as a structured tree of nodes (properties and their types), in addition to the raw JSON Schema view.

#### Scenario: Browsing the output schema
- **WHEN** the operator opens the output schema editor for a workflow
- **THEN** the system shows each schema node in a tree, with its name, type, and (if set) the step that produces it

### Requirement: Node-to-step mapping
The system SHALL let the operator map a schema node to the stage/step whose output populates it, persisted as an `x-producedBy` extension on that node within `schema.json`.

#### Scenario: Mapping a node to a step
- **WHEN** the operator selects a schema node and assigns it a producing step
- **THEN** the system records that step's id on the node (`x-producedBy`) and shows the mapping in the tree view

### Requirement: Scaffold a new step from an unmapped node
The system SHALL let the operator create a new stage or step directly from a selected schema node that has no mapped producer, pre-filling the new step's expected output shape from that node's schema type.

#### Scenario: Creating a step from an unmapped field
- **WHEN** the operator selects an unmapped schema node and chooses "Create step for this field"
- **THEN** the system creates a new step (in a new or existing stage, as chosen by the operator), maps the node to it, and opens the new step's detail editor

### Requirement: Unmapped-node warning
The system SHALL flag, without blocking, any schema node that has no mapped producing step, both in the editor and before a workflow run starts.

#### Scenario: Starting a run with unmapped nodes
- **WHEN** the operator starts a run for a workflow whose schema has one or more unmapped nodes
- **THEN** the system shows a non-blocking warning listing the unmapped nodes and proceeds with the run if the operator continues

### Requirement: Schema validation before save
The system SHALL validate an edited schema as well-formed JSON Schema (including any `x-producedBy` extensions referencing existing stage/step ids) before saving, consistent with the existing output schema validation requirement.

#### Scenario: Saving a schema with a dangling step reference
- **WHEN** the operator saves a schema edit whose `x-producedBy` value references a stage/step id that no longer exists
- **THEN** the system rejects the save, shows the validation error, and leaves the on-disk file unchanged

### Requirement: Merged structured output per file
The system SHALL merge each file's per-step outputs into a single structured JSON result according to the schema's node-to-step mapping, and validate that merged result against `schema.json` before writing it to the workflow's outputs.

#### Scenario: A file completes all stages
- **WHEN** a queued file completes all of a workflow's stages and steps
- **THEN** the system merges each step's output into one JSON result per the `x-producedBy` mapping, validates it against `schema.json`, and writes it to that workflow's `.analysis-state/<workflow-id>/outputs/`
