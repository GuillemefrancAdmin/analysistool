## 1. Server scaffolding

- [x] 1.1 Create `web-viewer/` directory with a minimal Node.js project (`package.json`, entry point) using plain `http` or a minimal framework (e.g. Express), per design.md Decision 1
- [x] 1.2 Implement server startup that accepts the `.analysis-state/` root path and port as configuration (CLI flag and/or env var), defaulting to binding `127.0.0.1` only (design.md Decision 5)
- [x] 1.3 Add `scripts/run_output_viewer.ps1` launch script that starts the Node server against the current directory's `.analysis-state/`, consistent with existing script conventions in `scripts/`
- [x] 1.4 Document the new Node.js runtime dependency and how to start the viewer (README section or inline script help text)

## 2. Manifest-driven navigation and overview

- [x] 2.1 Implement a route/handler that reads `.analysis-state/queue/manifest.json` and lists every tracked file with its current `status`
- [x] 2.2 Build the overview/index page UI listing all files and statuses (spec: output-web-viewer "Overview page lists all tracked files")
- [x] 2.3 Build folder-tree navigation mirroring `.analysis-state/outputs/` layout, linking to each file's detail page by the same relative path (spec: output-web-viewer "Navigation mirrors the analyzed source tree")

## 3. File detail rendering

- [x] 3.1 Implement a route that loads a given file's output folder (`<file>.json`, `<file>.md`, `diagram.mmd`, `.raw.txt` if present)
- [x] 3.2 Render `<file>.md` as formatted markdown when present; omit the section cleanly when absent (spec: output-web-viewer "File has no markdown narrative")
- [x] 3.3 Render `<file>.json` as a structured, human-readable breakdown of its sections (module metadata, functional requirements, technical debt, security findings, modernization recommendations, etc.), following `templates/source-code-analysis-schema.json`
- [x] 3.4 Integrate Mermaid.js client-side to render `diagram.mmd` content as a visual diagram (design.md Decision 2)
- [x] 3.5 Implement blocked/invalid-output handling: detect missing/unparseable `<file>.json`, show the state's `blocker_or_error` and any `.raw.txt` fallback content instead of erroring (spec: output-web-viewer "Graceful handling of blocked or invalid output")
- [x] 3.6 Implement in-progress/queued state handling: show a "not yet completed" indicator instead of attempting to render a report (spec: output-web-viewer "File still queued or in progress")

## 4. Search indexing

- [x] 4.1 Choose and add an in-memory search library (e.g. `minisearch` or `flexsearch`) per design.md Decision 4
- [x] 4.2 Implement an indexer that extracts textual fields from completed files' `<file>.json` (e.g. `primary_purpose`, requirement descriptions, security finding text, modernization plan steps) and `<file>.md`, excluding files without valid parsed output (spec: output-search "Search excludes incomplete or invalid reports from indexed content")
- [x] 4.3 Extract structured facet fields for filtering: technical debt `severity`, functional requirement `business_rule_type`, `modernization_recommendations.recommended_7r_strategy`, `business_impact.criticality_level`
- [x] 4.4 Build the index at server startup by scanning `.analysis-state/outputs/`
- [x] 4.5 Add a filesystem watcher (e.g. `chokidar`) on `.analysis-state/outputs/` and `manifest.json` to incrementally refresh the index as files complete (spec: output-search "Search index stays current with pipeline output")
- [x] 4.6 Add a manual "rebuild index" action (endpoint + UI control) as a fallback when the watcher misses changes

## 5. Search UI

- [x] 5.1 Build a search page/component with a free-text input and facet filter controls
- [x] 5.2 Wire free-text queries to the search index and render ranked results linking to each file's detail page (spec: output-search "Full-text search across analysis outputs")
- [x] 5.3 Implement facet filtering and combined text+facet queries (spec: output-search "Structured/faceted filtering on report fields", "Combining free text and a facet filter")
- [x] 5.4 Implement an empty-results state for searches with no matches

## 6. Verification

- [x] 6.1 Manually run the pipeline on a small sample of source files, start the viewer, and verify navigation, detail rendering (markdown, JSON, diagram), and search results match the on-disk output — done against a synthetic fixture reproducing the exact manifest.json/output_references shape (not an actual Ollama pipeline run, which needs the local model runtime this session doesn't have); navigation, markdown/JSON/diagram rendering, and search all verified against it. Re-verify against a real pipeline run when convenient.
- [x] 6.2 Verify a file left in a `blocked` state (or one with a forced-invalid JSON) renders the fallback state correctly instead of erroring
- [x] 6.3 Verify the viewer reflects a newly completed file (added while the pipeline runs) without restarting the server, for both navigation and search
- [x] 6.4 Verify the server binds to `127.0.0.1` by default and document how an operator would explicitly opt into broader network exposure
