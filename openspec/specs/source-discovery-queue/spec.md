# source-discovery-queue Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: Source file discovery scope
The queue generator SHALL discover candidate source files only under the configured discovery roots (`source code`, `Processus affaires`, `documentation`), SHALL exclude tooling/VCS directories (`.git`, `.analysis-state`, `.venv`, `venv`, `__pycache__`, `node_modules`, `dist`, `build`, `target`, `.idea`, `.vscode`) and dotfiles other than `.analysis-state`, and SHALL match files by a fixed extension allowlist plus a small set of special-cased filenames (`env.inc`, `global.config.php`, `dsn.html`, `dsnmssql.html`).

#### Scenario: File under an excluded directory is skipped
- **WHEN** the generator scans a discovery root that contains a nested `node_modules` (or other excluded) directory
- **THEN** no file under that excluded directory is added to the manifest

#### Scenario: File outside the discovery roots is ignored
- **WHEN** a source-looking file exists under `scripts/` or `skills/` (outside `source code`, `Processus affaires`, `documentation`)
- **THEN** the generator does not include it as a candidate

#### Scenario: Special-cased filename without a matching extension is included
- **WHEN** a file named `env.inc` exists under a discovery root
- **THEN** it is treated as a candidate file even though `.inc` handling is name-specific

### Requirement: Deterministic, collision-safe state filenames
The queue generator SHALL derive each file's state filename from its own relative path so that reruns never rename, duplicate, or reorder existing state records, and SHALL disambiguate files that share a base name (e.g. `README.md` in different folders) using a hash of the file's relative path.

#### Scenario: Two files share a base name
- **WHEN** two different discovered files both resolve to the base state name `readme.md.state.json`
- **THEN** each is assigned a distinct state filename suffixed with a hash of its own relative path, and re-running the generator produces the same two filenames again

#### Scenario: Single file with a unique base name
- **WHEN** only one discovered file resolves to a given base state name
- **THEN** that file's state filename is the plain base name with no hash suffix

### Requirement: Idempotent manifest and state generation
Re-running the queue generator SHALL be safe: it SHALL never overwrite an existing state file's recorded progress, and it SHALL rebuild `manifest.json` from current disk scan plus each file's existing state (if any) on every run.

#### Scenario: Rerun after a file has completed analysis
- **WHEN** the generator is run again after a file's state record already shows `status: completed` and stage progress
- **THEN** the file's existing state file is left untouched and the regenerated manifest entry reflects that same `completed` status and progress

#### Scenario: Brand-new file discovered
- **WHEN** a file has no corresponding state file under `.analysis-state/states/` or `.analysis-state/states/done/`
- **THEN** the generator creates a new state file for it with `status: queued` and `next_action: discover_and_queue_file`, and increments the "newly discovered" count in its summary output

#### Scenario: Completed file's state has moved to states/done/
- **WHEN** a previously completed file's state record now lives under `.analysis-state/states/done/<name>`
- **THEN** the generator points that file's manifest entry at the `done/` location instead of creating a duplicate blank state file at the old flat path

### Requirement: Manifest write safety
The queue generator SHALL write `manifest.json` (and any state file) via an atomic write-then-rename, so that a process concurrently reading the manifest (e.g. `queue_eta.ps1`) never observes a partially written file.

#### Scenario: Manifest is read while being regenerated
- **WHEN** `queue_eta.ps1` reads `manifest.json` at the same moment the generator is rewriting it
- **THEN** the reader sees either the complete old content or the complete new content, never a truncated/partial file

