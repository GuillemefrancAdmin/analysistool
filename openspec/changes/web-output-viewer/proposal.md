## Why

The pipeline (`scripts/run_analysis_pipeline.ps1` / `run_analysis_pipeline_parallel.ps1`) already writes a rich, self-contained analysis report per source file under `.analysis-state/outputs/<mirrored-source-path>/` — a structured `<file>.json` (module metadata, business rules, security findings, tech debt, modernization plan, etc.), an optional `<file>.md` narrative, and a `diagram.mmd` Mermaid diagram. Today the only way to consult this is by browsing the raw folder tree and opening individual files by hand, with no way to search across files (e.g. "which modules touch table X", "show all critical security findings", "which files are flagged for Rearchitect"). As the number of analyzed files grows, this stops scaling for anyone who isn't the person who ran the pipeline. We need a web-based way for users to read, navigate, and search these outputs.

## What Changes

- Add a local lightweight web server (Node or Python, run via a new script alongside the existing PowerShell pipeline scripts) that serves the contents of `.analysis-state/outputs/` as a browsable, readable web UI.
- Render each analyzed file's `<file>.md` narrative and `<file>.json` structured report (module metadata, functional requirements, security findings, technical debt, modernization recommendations, etc.) in a human-readable page, and render `diagram.mmd` as a rendered Mermaid diagram rather than raw text.
- Provide navigation that mirrors the source tree structure (matching the folder layout already produced under `outputs/`), plus an overview/index page listing all analyzed files with status.
- Add full-text and structured search across all analyzed files' `<file>.md` and `<file>.json` content (e.g. search by keyword, business rule type, severity, criticality level, recommended 7R strategy) with results linking to the relevant file's detail page.
- No authentication/access control is added in this change — the site is intended for trusted internal use, consistent with today's model where anyone who can read `.analysis-state/outputs/` can read the reports. This is a documented assumption, not an oversight (see design.md Non-Goals).
- The viewer reads pipeline output only; it does not trigger, control, or modify pipeline runs (starting/stopping analysis stays with the existing `run_analysis_pipeline*.ps1` / `stop_analysis_pipeline.ps1` scripts).

## Capabilities

### New Capabilities
- `output-web-viewer`: A local web server and UI for browsing the analyzed-file tree under `.analysis-state/outputs/` and reading each file's rendered markdown report, structured JSON findings, and rendered diagram.
- `output-search`: Full-text and structured search across all generated analysis outputs, returning ranked results that link into the `output-web-viewer` detail pages.

### Modified Capabilities
- None. This change only adds a read-only consumer of existing output artifacts; it does not change how `.analysis-state/` is written, structured, or persisted (see `analysis-state-persistence`).

## Impact

- **New code**: a new server application (language/framework TBD in design.md) and its UI, plus a launch script (e.g. `scripts/run_output_viewer.ps1` or equivalent) to start it — additive, no changes to existing pipeline scripts.
- **Affected systems**: reads `.analysis-state/outputs/**` and `.analysis-state/queue/manifest.json` (for status/index data) as documented in `analysis-state-persistence`; does not write to `.analysis-state/`.
- **Dependencies**: introduces a new runtime dependency (Node.js or Python, TBD in design.md) for the server, and a search-indexing library, neither of which the pipeline scripts currently require.
- **Operational**: adds a new local process users start when they want to consult results; no impact on pipeline run time or behavior.
