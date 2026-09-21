## Why

`openspec/specs/` is currently empty — the previous change proposal was cleared to start fresh. Without baseline specs, there is no agreed record of what the analysistool pipeline actually does today, so future changes have nothing to diff against. This change captures the existing, already-built system as OpenSpec capabilities, from the code and docs as they exist now (no new behavior is introduced).

## What Changes

- Document the source discovery & queue generation behavior of `scripts/generate_analysis_queue.ps1`.
- Document the sequential 9-stage pipeline execution behavior of `scripts/run_analysis_pipeline.ps1`.
- Document the parallel multi-GPU orchestration behavior of `scripts/run_analysis_pipeline_parallel.ps1`.
- Document the queue ETA reporting behavior of `scripts/queue_eta.ps1`.
- Document the state reset behavior of `scripts/reset_analysis_state.ps1`.
- Document the pipeline stop-control behavior of `scripts/stop_analysis_pipeline.ps1`.
- Document the per-file analysis agent contract defined by `skills/*` and `templates/source-code-analysis-schema.json`.
- Document the resumable state persistence contract defined by `.analysis-state/` and `templates/*.json`.

No code changes. This is a documentation-only baseline; `tasks.md` verifies each spec against the current implementation rather than instructing new work.

## Capabilities

### New Capabilities
- `source-discovery-queue`: Scans configured source roots, builds/refreshes the queue manifest and per-file state records idempotently.
- `sequential-pipeline-execution`: Drives the 9-skill analysis chain against queued files one at a time via a local Ollama endpoint, with resumable per-stage progress, stall detection, and Ollama-down recovery.
- `parallel-pipeline-orchestration`: Runs multiple sequential-pipeline workers concurrently, one per GPU, partitioning the queue across them.
- `queue-eta-reporting`: Estimates remaining time-to-completion for the queue from recorded per-file/per-stage timing.
- `analysis-state-reset`: Wipes generated queue/state/checkpoint/output artifacts to allow a clean restart, optionally regenerating the queue.
- `pipeline-stop-control`: Safely stops running pipeline worker processes without touching state or output.
- `legacy-source-analysis-agents`: The chained contract of LLM agent roles (sanitizer through architecture-spec-writer) that transform raw legacy source into structured findings and a final spec.
- `analysis-state-persistence`: The directory/file conventions under `.analysis-state/` that make the pipeline resumable and crash-safe.

### Modified Capabilities
(none — `openspec/specs/` is currently empty)

## Impact

- Affected paths (read-only, documented as-is): `scripts/generate_analysis_queue.ps1`, `scripts/run_analysis_pipeline.ps1`, `scripts/run_analysis_pipeline_parallel.ps1`, `scripts/queue_eta.ps1`, `scripts/reset_analysis_state.ps1`, `scripts/stop_analysis_pipeline.ps1`, `skills/*/SKILL.md`, `templates/*.json`, `.analysis-state/README.md`.
- No runtime, dependency, or API impact — this change only adds files under `openspec/`.
