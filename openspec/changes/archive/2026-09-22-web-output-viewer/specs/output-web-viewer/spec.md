## ADDED Requirements

### Requirement: Local web server serves analysis outputs
The system SHALL provide a local web server, started via a dedicated launch script, that reads directly from `.analysis-state/outputs/` and `.analysis-state/queue/manifest.json` and serves their contents as a browsable web UI, without requiring a separate build or export step.

#### Scenario: Starting the viewer
- **WHEN** the launch script is run against an existing `.analysis-state/` directory
- **THEN** a local web server starts and serving the viewer UI over HTTP, bound to `127.0.0.1` by default

#### Scenario: Viewer reflects new pipeline output without a rebuild step
- **WHEN** the analysis pipeline completes a new file after the viewer server has started
- **THEN** the newly completed file's report becomes visible in the running viewer without restarting the server or running a separate build command

### Requirement: Navigation mirrors the analyzed source tree
The viewer SHALL present a navigation structure that mirrors the folder layout of `.analysis-state/outputs/`, plus an overview/index page listing all files known to `manifest.json` together with their current status.

#### Scenario: Browsing to a file's report
- **WHEN** a user navigates the folder tree to a specific analyzed file
- **THEN** the viewer shows that file's report page, reachable via the same relative path structure used under `.analysis-state/outputs/`

#### Scenario: Overview page lists all tracked files
- **WHEN** a user opens the viewer's index/overview page
- **THEN** it lists every file present in `manifest.json`, each showing its current `status` (e.g. completed, blocked, queued)

### Requirement: File detail page renders report content
For a completed file, the viewer SHALL render the `<file>.md` narrative as formatted markdown, the `<file>.json` structured report as a human-readable breakdown of its sections (module metadata, functional requirements, technical debt, security findings, modernization recommendations, etc.), and `diagram.mmd` as a rendered diagram rather than raw text.

#### Scenario: Viewing a completed file's report
- **WHEN** a user opens the detail page for a file with status `completed`
- **THEN** the page shows the rendered markdown narrative (if present), the structured JSON report broken into readable sections, and the diagram rendered visually (not as raw Mermaid source text)

#### Scenario: File has no markdown narrative
- **WHEN** a completed file's output folder does not contain a `<file>.md`
- **THEN** the detail page still renders the JSON report and diagram, and omits the markdown section without error

### Requirement: Graceful handling of blocked or invalid output
The viewer SHALL detect when a file's `<file>.json` is missing or fails to parse and SHALL render an explicit blocked/raw-output state — showing the available `.raw.txt` content and the `blocker_or_error` reason from the file's state — instead of erroring or showing a blank page.

#### Scenario: File blocked before producing a valid report
- **WHEN** a user opens the detail page for a file whose status is `blocked` and whose output folder has no valid `<file>.json`
- **THEN** the page clearly indicates the file is blocked, shows the recorded `blocker_or_error` text, and shows the raw fallback text if a `.raw.txt` file is present

#### Scenario: File still queued or in progress
- **WHEN** a user opens the detail page for a file with status `queued` or `in_progress`
- **THEN** the page indicates the file has not yet completed analysis rather than attempting to render a report
