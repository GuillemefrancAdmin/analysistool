# pipeline-stage-registry Specification

## Purpose
TBD - created by archiving change normalize-pipeline-stages. Update Purpose after archive.
## Requirements
### Requirement: Single source of truth for the stage roster
The ordered list of per-file analysis stages SHALL be defined in exactly one place, loaded by both `run_analysis_pipeline.ps1` and `generate_analysis_queue.ps1`, rather than maintained as two independently hand-synchronized array literals.

#### Scenario: Both scripts agree on the roster by construction
- **WHEN** `run_analysis_pipeline.ps1` and `generate_analysis_queue.ps1` each need the full stage/agent name list
- **THEN** both obtain it from the same shared source, so no manual step is needed to keep them in sync and no divergence between them is possible without editing that one shared source

### Requirement: Stage identity is name-based, never a hardcoded position
Code that identifies a specific stage - for resume gating, for `Invoke-Stage`/`Save-Intermediate` calls, for advancing `last_completed_stage` - SHALL refer to that stage by its name, never by a numeric literal index into the stage list.

#### Scenario: Inserting a stage requires no renumbering
- **WHEN** a new stage is added to the shared registry at any position other than the end
- **THEN** no existing code that references a different, unrelated stage by its own name needs to change, because nothing anywhere holds that other stage's numeric position as a literal

#### Scenario: Resume gating derives its threshold from stage order, not a literal
- **WHEN** the runner computes whether a given stage should run for a resuming file
- **THEN** that stage's position is computed from its name's location in the shared registry at run time, not read from a hardcoded number in that stage's own code

### Requirement: Uniform middle stages execute generically
Stages that share the common shape - consume a composed subset of prior stages' results, call the model once, save the result as an intermediate, optionally write one named sibling output file - SHALL be declared as data (name, prompt reference, input composition, optional sibling output) and executed by one shared code path, rather than each having its own hand-written, copy-pasted execution block. Stages with genuinely distinct behavior (the sanitizer, which reads raw source rather than prior results; the final JSON-synthesis stage, which parses/validates/repairs its output and decides completion/blocking) remain their own dedicated code.

#### Scenario: Adding a uniform-shaped stage is a data change
- **WHEN** a new analysis stage is added whose behavior fits the common shape (compose input from named prior stages, call the model, save the result, optionally write one sibling file)
- **THEN** implementing it requires adding one entry to the shared stage table and its system prompt text, with no new hand-written execution block

### Requirement: One canonical empty per-agent usage template
Every place that needs a fresh, empty `token_usage` record for an agent (state-file seeding for newly discovered files, manifest-summary rebuilding, and the pipeline runner's defensive fallback for an agent not yet present in an older state file) SHALL obtain it from one canonical function, so the schema's required per-agent fields cannot independently drift out of sync between separate hand-written copies.

#### Scenario: All three consumers produce an identical empty record
- **WHEN** a fresh-file state seed, a manifest-summary rebuild, and the runner's defensive fallback each need an empty agent usage record
- **THEN** all three contain exactly the same set of fields, because all three call the same function rather than each maintaining its own literal

### Requirement: Supported backfill for a stage added after files already completed
A dedicated tool SHALL exist to propagate a newly added stage across files that completed the full chain before that stage existed: given the new stage's name, it SHALL rewind each such file's `last_completed_stage` (in both its state file and its manifest entry) to the stage immediately preceding the new one in the shared registry, reset its status to re-enter the queue, and zero its run-total counters, without altering the recorded per-agent history of stages that won't re-run.

#### Scenario: Backfill targets only files that predate the new stage
- **WHEN** the backfill tool is run for a newly added stage name
- **THEN** it only touches completed files whose recorded progress is at or beyond that stage's position, leaving files already re-processed past it (and files that never reached that far) unchanged

#### Scenario: Backfill preserves earlier stages' recorded history
- **WHEN** a file is rewound by the backfill tool
- **THEN** the per-agent `token_usage` entries for stages before the new stage's position are left exactly as recorded from the file's original run, and only the file's top-level run-total counters are reset

