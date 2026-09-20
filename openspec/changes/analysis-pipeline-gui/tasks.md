## 1. Project setup

- [ ] 1.1 Create the C# solution/project (WPF, .NET 8, MVVM via CommunityToolkit.Mvvm) named "Analysis Pipeline Studio" in `app/AnalysisPipelineStudio/`
- [ ] 1.2 Add a shared library project for file-system/state access (workflow catalog, queue, state, checkpoint, lock, output JSON read/write) usable by both the engine and the UI
- [ ] 1.3 Wire up an `IHostedService`/background worker host inside the app process, capable of running one worker pool per active workflow
- [ ] 1.4 Add the Windows Task Scheduler managed API dependency (e.g. `TaskScheduler` NuGet package) for use by workflow-scheduling (section 16)
- [ ] 1.5 Add project README covering how to build/run the app, that it supersedes `scripts/*.ps1`, that "workflow" is the app's core concept (the legacy analysis is one bundled workflow), and that first launch requires completing the LLM setup wizard

## 2. Repository migration to the `workflows/` layout

- [ ] 2.1 Write a one-time, idempotent migration tool that moves `skills/<id>/SKILL.md` → `workflows/legacy-source-analysis/skills/<id>/<id>/SKILL.md` (each existing stage becomes a stage with one step, reusing the stage id as its sole step's id)
- [ ] 2.2 Move `templates/source-code-analysis-schema.json` → `workflows/legacy-source-analysis/schema.json`
- [ ] 2.3 Generate `workflows/legacy-source-analysis/manifest.json` from the current 9-stage order documented in `documentation/diagram.md`, each stage wrapped around its single migrated step
- [ ] 2.4 Generate `workflows/legacy-source-analysis/workflow.json` (display name, description, source roots `source code/` and `Processus affaires/`)
- [ ] 2.5 Generate an initial `workflows/legacy-source-analysis/layout.json` with a simple auto-layout of the 9 single-step stages
- [ ] 2.6 Move `.analysis-state/{queue,states,checkpoints,locks,outputs}` → `.analysis-state/legacy-source-analysis/{queue,states,checkpoints,locks,outputs}`, preserving every existing file (real checkpoint/state/output history already on disk)
- [ ] 2.7 Verify the migration with a before/after file count and checksum comparison before removing the original `skills/`, `templates/source-code-analysis-schema.json`, and top-level `.analysis-state/{queue,states,checkpoints,locks,outputs}` paths
- [ ] 2.8 Confirm the app reads the migrated `workflows/legacy-source-analysis/` and `.analysis-state/legacy-source-analysis/` content unmodified thereafter (no further schema changes needed for that data)

## 3. Bootstrap app-wide config

- [ ] 3.1 Define the `workflows/<workflow-id>/workflow.json` schema (id, display name, description, source root(s), optional workflow-level model/temperature/endpoint defaults)
- [ ] 3.2 Define the `workflows/<workflow-id>/manifest.json` schema (stage id/display name/order; nested ordered `steps` list, each with id, display name, order, `skills/<stage-id>/<step-id>/SKILL.md` path, per-step model/temperature/timeout overrides)
- [ ] 3.3 Define the `workflows/<workflow-id>/layout.json` schema (per-stage and per-step canvas x/y position, keyed by id)
- [ ] 3.4 Define the `.analysis-state/app-config.json` schema (endpoint URL(s), model, worker count, timeouts, stall thresholds, GPU/auto-start settings) as app-wide defaults
- [ ] 3.5 Write a one-time bootstrap that seeds `.analysis-state/app-config.json` from `run_analysis_pipeline.ps1`'s current default parameter values (used only to pre-fill the setup wizard, not to skip it)
- [ ] 3.6 Implement the model/temperature/timeout resolution order: step override → stage override → workflow override → app-wide default

## 4. Workflow management (spec: workflow-management)

- [ ] 4.1 Build the workflow catalog view listing every `workflows/<workflow-id>/` directory with its display name, description, and source root(s)
- [ ] 4.2 Implement create-workflow (scaffold a new `workflows/<workflow-id>/` with empty `workflow.json`/`manifest.json`/`layout.json`/`skills/`/`schema.json`)
- [ ] 4.3 Implement clone-workflow (copy an existing workflow's `manifest.json`, `skills/`, `schema.json`, `layout.json` into a new workflow id)
- [ ] 4.4 Implement rename/edit-metadata for a workflow's display name and description
- [ ] 4.5 Implement delete-workflow with a confirmation step warning about loss of the workflow's definition and, if present, its `.analysis-state/<workflow-id>/` run history
- [ ] 4.6 Implement source-root configuration UI (add/remove/edit a workflow's source root list in `workflow.json`)
- [ ] 4.7 Implement active-workflow selection, propagated to the dashboard, canvas, stage editor, output schema editor, output browser, and chatbot
- [ ] 4.8 Implement workflow export (package `workflow.json`, `manifest.json`, `skills/`, `schema.json`, `layout.json` into a single portable file, excluding `.analysis-state/<workflow-id>/`)
- [ ] 4.9 Implement workflow import (unpack an exported file into a new `workflows/<workflow-id>/` and add it to the catalog)
- [ ] 4.10 Implement the in-memory draft model for the selected workflow (canvas/editor edits held in memory, not written to disk until saved)
- [ ] 4.11 Implement an unsaved-changes indicator, explicit save (writes `manifest.json`/`layout.json`/`schema.json`/step `SKILL.md` files), and discard (reverts to last-saved on-disk content)
- [ ] 4.12 Implement conflict detection: warn the operator if the chatbot writes to a workflow that currently has unsaved draft changes open

## 5. First-run LLM setup wizard (spec: workflow-assistant)

- [ ] 5.1 Detect missing/failing LLM configuration in `.analysis-state/app-config.json` on launch and route to a mandatory setup wizard before workflow management, the dashboard, editor, canvas, or output browser become reachable
- [ ] 5.2 Build wizard UI: endpoint URL, model name, and a "test connection" action
- [ ] 5.3 Implement connection validation (live test call to the Ollama-compatible endpoint) with clear success/failure feedback, including the URL/error attempted on failure
- [ ] 5.4 On successful test, persist the connection to `.analysis-state/app-config.json` and unlock the rest of the app
- [ ] 5.5 Expose the same wizard from Settings so the operator can change the LLM connection later

## 6. Workflow assistant chatbot (spec: workflow-assistant)

- [ ] 6.1 Build a persistent chatbot panel available from workflow management, the dashboard, the canvas, and the stage definition editor, backed by the LLM configured in `app-config.json`
- [ ] 6.2 Give the chatbot read access to the workflow catalog (`workflows/**`), the selected workflow's `manifest.json`, step `SKILL.md` contents, `schema.json` (with node-to-step mappings), `layout.json`, `app-config.json` settings, and current run state across workflows to ground its answers and actions
- [ ] 6.3 Implement drafting an entirely new workflow from a natural-language description (stages, steps, prompts, schema, suggested source root), creating it in the workflow catalog
- [ ] 6.4 Implement direct-write actions for low-risk changes (step prompt edits, reorder stages/steps, add stage/step, per-step/per-stage/per-workflow model/temperature/timeout overrides, schema edits, create/clone workflow, start/pause/resume) routed through the same save/validation path as the structured editors — applied immediately, no confirmation step
- [ ] 6.5 Implement a high-risk action classifier and confirmation gate that blocks execution until the operator explicitly confirms: removing a stage/step with existing completed state entries, deleting an entire workflow, resetting a workflow's entire queue, stopping/resetting a currently active run, changing the LLM connection away from a working one
- [ ] 6.6 Ensure any chatbot-initiated write that fails validation (invalid schema, malformed manifest) is rejected outright regardless of risk tier, with the error surfaced to the operator
- [ ] 6.7 Implement a chatbot action log recording every chatbot-initiated write (auto-applied or confirmed), including which workflow it affected, viewable by the operator and distinguishable from manual edits
- [ ] 6.8 Persist chat history for the current session (not required to survive app restarts)
- [ ] 6.9 Implement PowerShell script generation from chatbot requests, running the script as a child process and capturing stdout/stderr/exit code
- [ ] 6.10 Implement the default execution scope (the selected workflow's managed directories — `workflows/<workflow-id>/`, `.analysis-state/<workflow-id>/` — plus `.analysis-state/app-config.json` and an app scratch directory; no network access, no access to any workflow's source root(s) or other workflows' directories) and detect when a drafted script would exceed it
- [ ] 6.11 Route any script that exceeds the default scope, or that deletes/overwrites/performs a system-level change, through the same high-risk confirmation gate as task 6.5
- [ ] 6.12 Extend the chatbot action log (task 6.7) to record executed scripts' content and captured output alongside other chatbot-initiated actions

## 7. Pipeline engine: queue discovery (spec: pipeline-engine)

- [ ] 7.1 Port `generate_analysis_queue.ps1`'s file discovery/eligibility rules to C#, parameterized by a workflow's configured source root(s) instead of a hardcoded path
- [ ] 7.2 Implement rescan: add queue/state entries for new files under a workflow's source root(s), leave in-progress/completed files untouched
- [ ] 7.3 Implement queue/state JSON read-modify-write helpers matching `templates/queue-manifest-template.json` and `templates/state-file-template.json` shapes exactly, scoped under `.analysis-state/<workflow-id>/`

## 8. Pipeline engine: stage and step execution (spec: pipeline-engine)

- [ ] 8.1 Implement an Ollama-compatible HTTP client (`/v1/chat/completions`) for step calls, resolving model/temperature/timeout via the step → stage → workflow → app-wide override chain (task 3.6)
- [ ] 8.2 Implement sequential step execution within a stage: run a stage's steps one at a time in manifest order, persisting per-step progress to the file's state JSON after each step
- [ ] 8.3 Implement one-file-at-a-time stage execution loop across stages, updating `last_completed_stage`, `updated_at`, `token_usage`, `output_references` after each stage completes (all its steps done)
- [ ] 8.4 Implement error handling: on step failure, set `blocker_or_error` and status without advancing past that step or its stage
- [ ] 8.5 Implement per-step output merging into one structured JSON result per file, per the workflow's `schema.json` node-to-step (`x-producedBy`) mapping
- [ ] 8.6 Implement final merged-output validation against the workflow's `schema.json` and write results to `.analysis-state/<workflow-id>/outputs/`

## 9. Pipeline engine: workers, stalls, checkpoints, multi-workflow isolation (spec: pipeline-engine)

- [ ] 9.1 Implement multi-worker partitioning within a workflow using `.analysis-state/<workflow-id>/locks` to prevent double-claiming a file
- [ ] 9.2 Port stall-guard logic (per-worker average seconds/file, bootstrap default, stall multiplier) from `run_analysis_pipeline.ps1`, applied at the step level
- [ ] 9.3 Implement stall retry-once-then-block behavior
- [ ] 9.4 Implement checkpoint writing after each completed file, matching `templates/checkpoint-template.json`, under `.analysis-state/<workflow-id>/checkpoints/`
- [ ] 9.5 Implement resume-from-latest-checkpoint per workflow on app start, including mid-stage resume at the correct step
- [ ] 9.6 Implement optional per-endpoint `ollama serve` auto-start/GPU pinning, off by default, mirroring `-NoAutoStart`/`-CudaVisibleDevices`
- [ ] 9.7 Implement isolation between concurrently running workflows: verify a running workflow's workers never read, claim, or write another workflow's `.analysis-state/<workflow-id>/` directory
- [ ] 9.8 Support starting/running more than one workflow's worker pool at the same time within the same app process

## 10. Pipeline engine: run control (spec: pipeline-engine)

- [ ] 10.1 Implement start/pause/resume/stop actions per workflow on the worker host (finish in-flight step before pausing/stopping)
- [ ] 10.2 Implement reset-single-file (clear `last_completed_stage`, `blocker_or_error`, `output_references`, status back to `queued`) within a workflow
- [ ] 10.3 Implement reset-entire-queue for a workflow

## 11. Dashboard UI (spec: pipeline-dashboard)

- [ ] 11.1 Build the workflow switcher, showing all workflows and which currently have an active run
- [ ] 11.2 Build queue/file status view (path, status, last completed stage, current step if mid-stage, last updated) for the selected workflow, bound to a `FileSystemWatcher`-driven live view model
- [ ] 11.3 Build checkpoint/progress history view with per-checkpoint drill-down, scoped to the selected workflow
- [ ] 11.4 Build token usage and ETA panel (per-file, run-total, remaining-queue estimate) for the selected workflow
- [ ] 11.5 Wire start/pause/resume/stop/reset buttons to the engine for the selected workflow, reflecting its current run state
- [ ] 11.6 Build blocked/failed files list with inline retry/reset actions, scoped to the selected workflow
- [ ] 11.7 Debounce `FileSystemWatcher` events feeding the dashboard, watching only the selected workflow plus any others currently running, to avoid UI-thread flooding during full-queue runs
- [ ] 11.8 Show scheduled-run history (from workflow-scheduling, section 16) in the same views as manually started runs

## 12. Stage and step definition editor (spec: stage-definition-editor)

- [ ] 12.1 Build ordered stage/step list view sourced from the selected workflow's `manifest.json`
- [ ] 12.2 Implement reorder (drag/move) of stages, and of steps within a stage, with manifest persistence
- [ ] 12.3 Implement add-stage and add-step (create new `workflows/<workflow-id>/skills/<stage-id>/<step-id>/SKILL.md` + manifest entry) and remove-stage/remove-step (with confirmation warning about existing completed state)
- [ ] 12.4 Implement `SKILL.md` section parser (Role/Mission/Inputs/Responsibilities/Workflow/Expected output/Quality rules) and structured form editor with round-trip save, scoped per step
- [ ] 12.5 Implement raw Markdown fallback editor for non-standard step files
- [ ] 12.6 Implement per-step model/temperature/timeout override fields, falling back to the step's stage, then the workflow's, then the app-wide `app-config.json` defaults
- [ ] 12.7 Expose a save/validation entry point that section 6's chatbot and the canvas (section 13) can call directly, so chatbot-initiated writes, canvas edits, and manual form edits share one save/validation path

## 13. Workflow canvas (spec: workflow-canvas)

- [ ] 13.1 Build the canvas rendering surface: stage nodes containing their step nodes, connected in execution order, positioned per `layout.json`
- [ ] 13.2 Implement add/remove/reorder of stages and steps directly on the canvas, persisting structural changes to `manifest.json` via the shared save path (task 12.7)
- [ ] 13.3 Implement drag-to-reposition, persisting only to `layout.json` (never to `manifest.json`)
- [ ] 13.4 Implement node selection opening the corresponding step's/stage's detail editor (section 12)
- [ ] 13.5 Implement the sequential-only constraint: prevent the operator from wiring a step to more than one following step within the same stage, with a message that branching isn't supported in this version

## 14. Output schema editor (spec: output-schema-editor)

- [ ] 14.1 Build the structured schema tree view for the selected workflow's `schema.json`, alongside the existing raw JSON view
- [ ] 14.2 Implement node-to-step mapping UI, persisting `x-producedBy` on each mapped schema node
- [ ] 14.3 Implement "create step for this field" from a selected unmapped node, pre-filling the new step's expected output shape and wiring the mapping
- [ ] 14.4 Implement the non-blocking unmapped-node warning, shown in the editor and before a run starts
- [ ] 14.5 Extend schema validation (JSON Schema well-formedness) to also check that every `x-producedBy` value references an existing stage/step id, rejecting the save otherwise
- [ ] 14.6 Wire schema/mapping saves through the shared save/validation path (task 12.7)

## 15. Output browser (spec: output-browser)

- [ ] 15.1 Build outputs tree view mirroring source-file structure under the selected workflow's `.analysis-state/<workflow-id>/outputs/`
- [ ] 15.2 Implement "View output" jump from a completed queue entry to its generated artifacts
- [ ] 15.3 Implement search-by-name/path-substring across the selected workflow's outputs
- [ ] 15.4 Implement markdown rendering and JSON pretty-printing for report viewers
- [ ] 15.5 Implement field-to-step provenance display in the JSON viewer, using the workflow's `schema.json` node-to-step mapping
- [ ] 15.6 Verify no browsing/editing entry point exists anywhere in the app for any workflow's source root(s) or for another workflow's outputs while a different workflow is selected

## 16. Workflow scheduling (spec: workflow-scheduling)

- [ ] 16.1 Implement a headless/unattended launch mode: a command-line flag identifying a target workflow, which runs it to completion/stop/time-limit with no window shown, then exits
- [ ] 16.2 Implement single-instance detection (named mutex) and a named-pipe handoff so a headless launch while the app is already open sends the run request to the running instance instead of starting a duplicate process
- [ ] 16.3 Implement scheduled-run creation: build a Windows Scheduled Task via the Task Scheduler API with a trigger for the chosen start date/time and recurrence, and an action that launches the app in headless mode targeting the chosen workflow
- [ ] 16.4 Map "max run time" directly to the scheduled task's `ExecutionTimeLimit`
- [ ] 16.5 Map "retry count" / "retry interval" directly to the scheduled task's `RestartCount` / `RestartInterval`
- [ ] 16.6 Build the scheduling UI: list/create/edit/delete scheduled runs, showing target workflow, next run time, recurrence, max run time, and retry settings, backed by the Task Scheduler API's own success/failure results
- [ ] 16.7 Scope task creation to the current user's task folder (no elevated/"run whether user is logged on or not" mode) so scheduling doesn't require admin rights by default
- [ ] 16.8 Record scheduled-run start/completion/outcome the same way a manually started run is recorded, so it appears in the dashboard (task 11.8) and, if applicable, the chatbot action log

## 17. Parity validation and migration sign-off

- [ ] 17.1 Run the C# engine against a copy of the migrated `legacy-source-analysis` queue and compare resulting state/checkpoint/output JSON against a `.ps1`-driven run on the same fixture
- [ ] 17.2 Fix any behavioral drift found in stall timing, worker partitioning, or checkpoint content
- [ ] 17.3 Add a header comment to each `scripts/*.ps1` file noting it is superseded by the app
- [ ] 17.4 Update `documentation/diagram.md` to reflect the manifest-driven stage/step list for `legacy-source-analysis` (regenerate or hand-sync, per design.md's open question resolution)
- [ ] 17.5 Sign off on the repository migration (task 2) by confirming the pre-migration `.analysis-state/` checkpoint/state/output file counts match the post-migration `.analysis-state/legacy-source-analysis/` counts
- [ ] 17.6 Verify single-instance handoff (task 16.2) by triggering a scheduled task both while the app is closed and while it's already open, confirming exactly one run starts either way
