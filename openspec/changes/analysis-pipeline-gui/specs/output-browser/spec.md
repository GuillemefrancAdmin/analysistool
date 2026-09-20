## ADDED Requirements

### Requirement: Browse generated outputs by source file
The system SHALL let the operator browse the selected workflow's `.analysis-state/<workflow-id>/outputs/**` using the same folder structure as that workflow's analyzed source tree, and open a given file's generated artifacts (JSON report, markdown report, diagrams) directly.

#### Scenario: Locating a file's output
- **WHEN** the operator selects a completed file from a workflow's queue view and chooses "View output"
- **THEN** the system opens that file's corresponding generated artifacts from that workflow's `.analysis-state/<workflow-id>/outputs/`

### Requirement: Search outputs
The system SHALL let the operator search the selected workflow's generated outputs by file name or path substring and show matching results.

#### Scenario: Searching by partial name
- **WHEN** the operator types a partial file name into the output search box
- **THEN** the system shows all matching generated artifacts for the selected workflow whose source path or file name contains that substring

### Requirement: Render report content
The system SHALL render markdown reports as formatted text and pretty-print JSON reports, rather than showing raw unformatted file content.

#### Scenario: Viewing a markdown report
- **WHEN** the operator opens a generated markdown report
- **THEN** the system renders it with headings, lists, and code blocks formatted, not as plain unformatted text

### Requirement: Field-to-step provenance in the JSON viewer
The system SHALL let the operator see, for a generated JSON report, which stage/step produced each field, using the workflow's schema node-to-step mapping (`x-producedBy`).

#### Scenario: Inspecting where a field came from
- **WHEN** the operator views a generated JSON report and selects a field
- **THEN** the system shows which stage and step produced that field, per the workflow's `schema.json` mapping

### Requirement: No editing of source roots or other workflows' outputs
The system SHALL restrict the output browser to the selected workflow's own `.analysis-state/<workflow-id>/outputs/**` and SHALL NOT provide browsing or editing UI for any workflow's configured source root(s) (e.g. `source code/` or `Processus affaires/` for the built-in `legacy-source-analysis` workflow) or for another workflow's outputs while a different workflow is selected.

#### Scenario: Attempting to browse excluded folders
- **WHEN** the operator looks for a way to open or edit files under a workflow's source root(s) from within the application
- **THEN** no such browsing or editing UI is present; those paths are used only internally by the pipeline engine for queue discovery
