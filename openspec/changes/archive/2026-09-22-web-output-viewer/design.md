## Context

`scripts/run_analysis_pipeline.ps1` / `run_analysis_pipeline_parallel.ps1` already write, per analyzed source file, a self-contained folder under `.analysis-state/outputs/<mirrored-source-path>/` containing a copy of the source, `intermediates/` stage text, a strict-schema `<file>.json` report (see `templates/source-code-analysis-schema.json`: module metadata, functional requirements, technical debt, security findings, modernization recommendations, per-file `output_references`), an optional `<file>.md` narrative, and a `diagram.mmd` Mermaid diagram (per `analysis-state-persistence`). `.analysis-state/queue/manifest.json` is the live index of every discovered file and its status (`analysis-state-persistence`, `source-discovery-queue`). Today the only consumption path is opening these files directly in a filesystem/editor.

The user has chosen a **local lightweight web server** (not a static site build) specifically so the viewer stays live/current as the pipeline runs, without a separate build step, and has explicitly accepted **no authentication** for this change — the site is trusted-internal-use, same trust boundary as the `.analysis-state/outputs/` folder itself today.

## Goals / Non-Goals

**Goals:**
- Serve a browsable, always-current view of `.analysis-state/outputs/` and `.analysis-state/queue/manifest.json` without requiring a rebuild/reindex step between pipeline runs and viewer use.
- Render `<file>.md` as formatted markdown, `<file>.json` as a structured human-readable report, and `diagram.mmd` as a rendered Mermaid diagram.
- Provide full-text and structured/faceted search (by severity, business rule type, 7R strategy, criticality, etc.) across all analyzed files, linking results to detail pages.
- Keep the new dependency footprint small and consistent with this repo's low-ceremony, script-driven style (no build pipeline, no database).

**Non-Goals:**
- Authentication/authorization, multi-tenant access control, or audit logging of who viewed what (explicit decision — trusted internal use only, see proposal.md).
- Editing analysis output, re-triggering, or controlling pipeline runs from the web UI (that remains the job of the existing `run_analysis_pipeline*.ps1` / `stop_analysis_pipeline.ps1` scripts).
- Public/internet-facing hosting, TLS termination, or horizontal scaling — this is a single local process for internal consultation.
- Changing the on-disk output format defined by `analysis-state-persistence` — the viewer is a read-only consumer.

## Decisions

**1. Runtime: Node.js, plain `http`/minimal framework, server-rendered HTML (no SPA framework).**
Node is already available in this environment (verified `npx` works) and gives easy access to markdown/Mermaid tooling via npm without introducing a Python dependency alongside PowerShell. A minimal server (Express or Node's built-in `http`) with server-rendered templates keeps footprint and cognitive overhead low, matching the rest of the repo (PowerShell scripts, no build pipelines, no frontend framework). Alternative considered: Python (Flask/FastAPI) — equally viable but rejected only to avoid mixing two extra runtimes (PowerShell + Python + Node) when one (Node) suffices.

**2. Rendering: `marked` (or equivalent) for markdown server- or client-side; Mermaid.js loaded client-side to render `diagram.mmd` content in the browser.**
Avoids a server-side headless-browser diagram render step; Mermaid's browser runtime can render the raw `.mmd` text directly, which the server just needs to pass through as text.

**3. Data access: read directly from `.analysis-state/` on each request / at startup — no copy, cache database, or separate index store.**
The output tree is the source of truth and already self-contained per file (`analysis-state-persistence`). Navigation and status come from `manifest.json`; detail pages read the corresponding output folder on demand. This avoids a second, potentially stale copy of the data.

**4. Search: an in-memory full-text/faceted index (e.g. `minisearch` or `flexsearch`) built at server startup from all `<file>.json`/`<file>.md` content, kept fresh via a filesystem watcher (e.g. `chokidar`) on `.analysis-state/outputs/` and `.analysis-state/queue/manifest.json`, plus a manual "rebuild index" action as a fallback.**
Given the expected scale (one legacy codebase's worth of analyzed files, not web-scale corpora), an in-memory index avoids operating a separate search service (e.g. Elasticsearch) while still supporting free-text and structured filtering (severity, `business_rule_type`, `recommended_7r_strategy`, `criticality_level`, etc.) pulled from the JSON schema fields.

**5. No authentication; bind to `127.0.0.1` by default.**
Per the explicit product decision (trusted internal use). To reduce accidental exposure, the server SHALL default to binding localhost-only; exposing it on a shared network is an explicit opt-in configuration choice left to the operator, not a default.

**6. Graceful handling of incomplete/blocked files.**
Per `run_analysis_pipeline.ps1`, a file whose final-stage output fails to parse as JSON falls back to a `.raw.txt` file and a `blocker_or_error` state. The viewer SHALL detect missing/invalid `<file>.json` and render an explicit "blocked / raw output only" state (showing the raw text) instead of erroring, using `manifest.json` status as the source of truth for why.

## Risks / Trade-offs

- **[Risk] No authentication exposes security findings, credential/secret-usage notes, and PII-handling assessments to anyone who can reach the port.** → Mitigation: localhost-only default bind (Decision 5); document in the launch script's output and README that network exposure is an explicit, unsupported-by-default opt-in.
- **[Risk] In-memory search index can drift from disk if the watcher misses an event (e.g. bulk file operations, network filesystem quirks).** → Mitigation: watcher-based incremental refresh plus a manual "rebuild index" endpoint/button as a fallback; index rebuild is cheap enough (single-codebase scale) to run in full when triggered.
- **[Risk] Large `<file>.json` reports loaded eagerly for every file at startup could slow indexing or memory usage as the analyzed codebase grows.** → Mitigation: index only the fields needed for search/facets (not full JSON blobs) and lazy-load full JSON only when a detail page is requested.
- **[Risk] New Node.js dependency where none existed before (repo is currently pure PowerShell + templates).** → Mitigation: document the requirement clearly in the launch script and a short README section; keep dependencies minimal (no bundler/build step required to run the server).
- **[Risk] Malformed or partial output (blocked files, raw-text fallback) crashing detail/search rendering.** → Mitigation: explicit handling per Decision 6, covered by specs.

## Migration Plan

Greenfield, additive change — no existing data, schema, or script is modified.
1. Add the new server application and its assets under a new directory (e.g. `web-viewer/`).
2. Add a launch script (e.g. `scripts/run_output_viewer.ps1`) that starts the Node server pointed at `.analysis-state/`, consistent with how other scripts in `scripts/` are invoked.
3. Document usage (start command, default port, localhost-only default) alongside the existing pipeline script docs.
Rollback: stop the process / remove the new directory and script — no persisted state is created or altered outside the new server's own runtime memory.

## Open Questions

- Exact npm packages (Express vs. built-in `http`; `minisearch` vs. `flexsearch`) — left to implementation as long as Decisions 1–4 hold; non-blocking.
- Default port and configuration mechanism (env var vs. CLI flag) — implementer's choice; suggest a sensible default (e.g. `5173` or similar) documented in tasks.
- Whether a future change should add optional authentication for shared/network deployment — explicitly deferred, not blocking this change.
