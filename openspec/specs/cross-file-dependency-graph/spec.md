# cross-file-dependency-graph Specification

## Purpose
TBD - created by archiving change add-cross-file-dependency-graph. Update Purpose after archive.
## Requirements
### Requirement: File-to-file dependency resolution
The graph builder SHALL resolve each completed file's `dependencies_and_integrations.internal_module_dependencies` entries against the corpus of analyzed files' own `module_metadata.file_path` values, using tiered matching (exact relative path, then basename with extension, then basename without extension, each case-insensitive, most specific first), and SHALL classify every entry into exactly one of three outcomes: resolved (exactly one match at the first tier that produces any match), ambiguous (more than one match at that tier), or unresolved (no match at any tier) — never silently dropped and never silently guessed when ambiguous.

#### Scenario: Unambiguous basename match resolves
- **WHEN** a file's `internal_module_dependencies` contains an entry that, ignoring extension and case, matches exactly one other analyzed file's basename
- **THEN** the graph records a resolved edge from the source file to that matched file

#### Scenario: Multiple candidates at the same tier stay ambiguous
- **WHEN** a dependency entry matches more than one analyzed file at the first tier that produces any match
- **THEN** the graph records it as ambiguous, listing every candidate, rather than picking one

#### Scenario: No candidate at any tier stays unresolved
- **WHEN** a dependency entry matches no analyzed file at any resolution tier
- **THEN** the graph records it as unresolved (external reference or unrecognized name) rather than omitting it

### Requirement: File-to-table usage map
The graph builder SHALL aggregate every completed file's `dependencies_and_integrations.database_interactions` entries by `target_entity`, producing, for each distinct table/entity, the set of files that interact with it and each interaction's `operation_type`.

#### Scenario: Table usage aggregated across files
- **WHEN** two or more completed files each have a `database_interactions` entry with the same `target_entity`
- **THEN** the file-to-table map lists all of those files under that entity, each with its own recorded `operation_type`

### Requirement: Graph building is read-only and non-interfering with pipeline state
The graph builder SHALL only read completed files' output JSON under `.analysis-state/outputs/`, and SHALL NOT read or write `manifest.json`, any per-file state file, or take any cross-process lock.

#### Scenario: No manifest or state access
- **WHEN** the graph builder runs, including while pipeline workers are actively processing other files
- **THEN** it does not open `manifest.json` or any file under `.analysis-state/states/`, and its own execution has no effect on pipeline state

### Requirement: Graph output includes both machine- and human-readable artifacts
The graph builder SHALL produce a machine-readable JSON artifact representing the full resolved graph and table map, and a separate human-readable summary report, both under a dedicated output location distinct from per-file outputs and pipeline state.

#### Scenario: Summary report is inspectable without parsing JSON
- **WHEN** the graph builder completes a run
- **THEN** it prints or writes a plain-text summary covering at minimum: total files/edges/tables processed, and resolved/ambiguous/unresolved edge counts

