## Why

The pipeline analyzes every source file in complete isolation — each of the ten agent stages, the queue/state model, and every existing report all operate on one file at a time. That's confirmed by direct investigation of `openspec/specs/legacy-source-analysis-agents/spec.md` and `scripts/`: nothing anywhere stitches per-file outputs into a system-level picture. For a **rewrite** migration (this project's stated target), the actual planning question isn't "what does file X do" — the pipeline already answers that reasonably well after this session's fixes — it's "which files form one coherent unit that has to move together," "what breaks if I touch this file," and "which tables/files are so heavily depended-upon that they need extra care." None of that is answerable from any single file's report, no matter how good that report gets.

The data needed already exists, mostly unlinked: every completed file's `dependencies_and_integrations.internal_module_dependencies` names other files/programs it references (as free text, not resolved against the actual corpus), and `dependencies_and_integrations.database_interactions` records structured table read/write operations. Building the graph is a **resolution/aggregation problem over already-extracted data, not a new analysis problem** — no new LLM calls needed.

## What Changes

- New read-only script that builds two graphs from the completed corpus's existing JSON outputs:
  - **File→file graph**: resolves each file's `internal_module_dependencies` free-text entries against the actual set of analyzed file paths (fuzzy match: exact path, then basename with/without extension, case-insensitive), producing real edges. Entries that don't resolve are kept as explicit "unresolved" nodes (external reference or unrecognized name), never silently dropped; entries that match more than one file are kept as explicit "ambiguous," never silently guessed.
  - **File→table map**: aggregates `dependencies_and_integrations.database_interactions` records across all files by `target_entity`, producing which files READ/WRITE/UPDATE/DELETE/etc. each table.
- Output as a JSON artifact (machine-readable, for future tooling — e.g. a web-viewer graph view, a later change) plus a human-readable summary report (files by fan-in/fan-out, tables by file-count, resolution/ambiguity counts) in the same reporting style as `queue_eta.ps1`/`verify_synthesis_quality.ps1`.

Explicitly out of scope, left as natural follow-ups once this data exists to evaluate against:
- Graph visualization (web-viewer integration).
- Connected-component/clustering analysis to suggest concrete "rewrite as one unit" groupings — valuable, but should be designed against what the resolved graph actually looks like, not speculatively now.
- Cross-referencing `data_lineage.tables_and_entities` (a secondary, unstructured table-name field) against the primary `database_interactions`-derived map.

## Capabilities

### New Capabilities
- `cross-file-dependency-graph`: repo-wide file-to-file and file-to-table dependency graphs, built by resolving/aggregating already-extracted per-file analysis data — the first capability in this project that operates across files rather than on one file at a time.

### Modified Capabilities
(none)

## Impact

- New script (e.g. `scripts/build_dependency_graph.ps1`), read-only against `.analysis-state/outputs/`, no pipeline/manifest changes.
- Graph completeness is bounded by `internal_module_dependencies`' own content quality, which `fix-architecture-spec-synthesis` did not specifically target (that change fixed `functional_requirements`/`technical_debt_and_code_smells`/`external_library_dependencies`/`database_interactions`, not `internal_module_dependencies`). A pre-fix measurement found it already comparatively healthy (52% real content, 26% plausibly-legitimately-empty, 22% placeholder) — worth re-measuring against the post-re-run corpus before or alongside building this, since it's the graph's primary input.
