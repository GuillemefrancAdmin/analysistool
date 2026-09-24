## Context

Every completed file's report JSON has `module_metadata.file_path` set programmatically by the script itself (`$parsed.module_metadata.file_path = $relativePath`, `run_analysis_pipeline.ps1`), not by the model — a reliable, trustworthy join key, unlike most other fields in the report. `dependencies_and_integrations.internal_module_dependencies` is free-text strings the model wrote (e.g. `"gerepile"`, `"global_procedure_division.cbl"`), with no guarantee of matching how the *referenced* file's own `file_path` is recorded. `dependencies_and_integrations.database_interactions` is already structured (`operation_type` enum, `target_entity`, `execution_mechanism`) — an aggregation problem, not a resolution problem.

`verify_synthesis_quality.ps1` (from `fix-architecture-spec-synthesis`) already established the pattern for a read-only, whole-corpus script that iterates `.analysis-state/outputs/**/*.json`: this script follows the same discovery approach.

## Goals / Non-Goals

**Goals:**
- Resolve `internal_module_dependencies` free-text entries against the actual corpus of analyzed file paths, with every entry ending up in exactly one of three buckets: resolved (exactly one matching file), ambiguous (more than one candidate at the same match tier), or unresolved (no candidate at any tier) — never silently dropped or silently guessed.
- Aggregate `database_interactions` into a file↔table map.
- Produce both a machine-readable JSON artifact and a human-readable summary report.

**Non-Goals:**
- Graph visualization, clustering/connected-component analysis, or migration-unit recommendations — explicitly deferred to a follow-up once this data exists to design against.
- Any change to the analysis pipeline itself, or to how `internal_module_dependencies`/`database_interactions` are extracted — this reads already-produced output, unchanged.
- Cross-referencing `data_lineage.tables_and_entities` (a secondary, unstructured table-name field) — `database_interactions` is the richer, structured source; revisit only if the resulting map looks incomplete against it.

## Decisions

**Resolution runs in tiers, most-specific first, and only accepts a tier's result if it's unambiguous: (1) exact relative-path match, (2) basename-with-extension match, (3) basename-without-extension match — each case-insensitive.** COBOL/4GL cross-references commonly name a "program" without its file extension (`"gerepile"` referring to `gerepile.4gl`), so extension-optional matching is necessary; but trying looser tiers first risks false-positive matches the stricter tiers would have avoided, hence strict-to-loose ordering. A tier that matches more than one file stops resolution at "ambiguous" rather than falling through to a looser tier that might coincidentally disambiguate — a looser tier is by construction less reliable, not a legitimate tiebreaker.
- *Alternative considered*: fuzzy string-distance matching (edit distance, etc.). Rejected — adds a whole class of "confidently wrong" matches (two similarly-named-but-unrelated programs) that this design deliberately avoids by preferring an honest "unresolved"/"ambiguous" bucket over a guessed edge.

**No PowerShell-7 relaunch guard**, unlike `queue_eta.ps1`/`backfill_new_stage.ps1`/`verify_synthesis_quality.ps1`. Each of those needed PS7 for a specific, concrete reason (manifest.json's size defeating Windows PowerShell 5.1's `ConvertFrom-Json`; `Test-Json` not existing before PS 6.1). This script only parses individual per-file report JSONs, each tens of KB — well within what Windows PowerShell 5.1 handles natively. Adding the guard anyway "for consistency" would be unnecessary complexity with no correctness benefit here.

**Output location: a new `.analysis-state/dependency-graph/` folder** (`graph.json` + a human-readable summary), separate from `.analysis-state/outputs/` (per-file reports) and `.analysis-state/queue/` (manifest) — this is a derived, corpus-wide artifact, not a per-file output or pipeline state, and deserves its own space rather than overloading either existing convention.

**No mutex, no manifest.json access at all.** This script never reads or writes `manifest.json` or any per-file state file — purely a read over `.analysis-state/outputs/*.json` and a write to its own new output folder. Structurally simpler and safer than the other reporting scripts, and explicitly non-interfering with a live pipeline run.

## Risks / Trade-offs

- **[Risk] Graph completeness is bounded by `internal_module_dependencies`'s own content quality (52% real / 26% empty / 22% placeholder, pre-`fix-architecture-spec-synthesis` measurement), which that change didn't target.** → Mitigation: not something this change can fix — noted in the proposal as worth re-measuring first; the resolution-tier design (Decision 1) at least ensures the graph is honest about what it can't resolve, rather than compounding upstream quality problems with resolution-guessing on top.
- **[Trade-off] A file referenced only by name that happens to collide with an unrelated file sharing the same basename in a different subsystem produces an "ambiguous" result rather than a resolved edge**, even in cases a human could disambiguate from context (e.g. subsystem proximity). → Accepted for a first version: an honest "ambiguous" bucket is inspectable and fixable later (e.g. by adding subsystem-proximity as a future tiebreaker tier); a silently-wrong edge is not.

## Migration Plan

None — new, read-only, additive tooling. No effect on the pipeline, manifest, or any existing output.

## Open Questions

- Exact JSON shape for `graph.json` (adjacency-list vs. edge-list, etc.) — implementation-time decision; either is a strict superset of what the human-readable summary needs, so this doesn't block starting.
- Whether "ambiguous" entries should list all candidate files in the output (recommended, for later manual disambiguation) — implementation-time, not a design-level fork.
