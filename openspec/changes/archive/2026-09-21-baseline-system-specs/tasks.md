## 1. Verify source-discovery-queue spec

- [x] 1.1 Confirm discovery roots, exclusions, and extension/special-filename matching against `scripts/generate_analysis_queue.ps1`
- [x] 1.2 Confirm deterministic/hash-disambiguated state filenames against `Get-StateNameMap`/`Get-PathHash`
- [x] 1.3 Confirm idempotent rerun behavior (no overwrite of existing state, `done/` redirect) against `New-ManifestEntry`/`Write-StateFileIfMissing`
- [x] 1.4 Confirm atomic manifest write against `Write-Utf8NoBom`

## 2. Verify sequential-pipeline-execution spec

- [x] 2.1 Confirm nine-stage order and per-stage context chaining against `Invoke-FileAnalysis` in `scripts/run_analysis_pipeline.ps1`
- [x] 2.2 Confirm resume-from-last-completed-stage behavior against `resumeIndex` logic
- [x] 2.3 Confirm stall-budget and retry-once-then-block behavior against the `attemptLoop` catch block
- [x] 2.4 Confirm Ollama-down wait/restart/retry behavior against the same catch block
- [x] 2.5 Confirm worker partitioning by path hash against `Get-PathWorkerHash` and `Main`
- [x] 2.6 Confirm cross-process-safe manifest merge against `Save-Manifest`
- [x] 2.7 Confirm lock file registration/cleanup against the top-of-script lock block and the `finally` in `Main`
- [x] 2.8 Confirm final-stage JSON parse success/failure handling against the stage-9 block in `Invoke-FileAnalysis`

## 3. Verify parallel-pipeline-orchestration spec

- [x] 3.1 Confirm one-Ollama-instance-per-GPU bootstrap against `Start-OllamaInstanceIfNeeded` in `scripts/run_analysis_pipeline_parallel.ps1`
- [x] 3.2 Confirm one-worker-job-per-instance launch against the `Start-Job` loop
- [x] 3.3 Confirm no-replay output streaming and single failure-line reporting against `Drain-JobOutput`
- [x] 3.4 Confirm periodic ETA invocation against the polling `while` loop
- [x] 3.5 Confirm final run summary against the post-loop summary block

## 4. Verify queue-eta-reporting spec

- [x] 4.1 Confirm average-elapsed-time computation and zero-completed guard against `scripts/queue_eta.ps1`
- [x] 4.2 Confirm stage-fraction proration against `Get-RemainingSecondsEstimate`
- [x] 4.3 Confirm worker-count division against the `$etaSeconds` computation

## 5. Verify analysis-state-reset spec

- [x] 5.1 Confirm deletion scope (states/checkpoints/outputs/manifest, README preserved) against `scripts/reset_analysis_state.ps1`
- [x] 5.2 Confirm live-worker detection and termination-before-delete against the lock-scanning block
- [x] 5.3 Confirm confirmation prompt / `-Force` behavior
- [x] 5.4 Confirm already-clean no-op path
- [x] 5.5 Confirm `-Regenerate` invokes `generate_analysis_queue.ps1`

## 6. Verify pipeline-stop-control spec

- [x] 6.1 Confirm live-lock discovery and stale-lock cleanup against `scripts/stop_analysis_pipeline.ps1`
- [x] 6.2 Confirm it touches only process/lock state, never state/output/manifest files
- [x] 6.3 Confirm confirmation prompt / `-Force` behavior

## 7. Verify legacy-source-analysis-agents spec

- [x] 7.1 Confirm all nine chained agent `SKILL.md` files exist with role/mission/inputs/responsibilities/expected-output/schema-coverage sections
- [x] 7.2 Confirm each stage's documented input chain matches the `$userContent` composition per stage in `Invoke-FileAnalysis`
- [x] 7.3 Confirm `architecture-spec-writer`'s owned schema sections against its `SKILL.md` "Schema coverage" section and `templates/source-code-analysis-schema.json`
- [x] 7.4 Confirm `file-queue-orchestrator-agent`'s role boundary (coordination only, no source interpretation) against its `SKILL.md`

## 8. Verify analysis-state-persistence spec

- [x] 8.1 Confirm `.analysis-state/` directory layout and state-file field list against `.analysis-state/README.md` and `templates/state-file-template.json`
- [x] 8.2 Confirm done/blocked relocation behavior against `Move-CompletedStateFile`/`Move-BlockedStateFile`
- [x] 8.3 Confirm checkpoint fields and write timing against `Write-Checkpoint` and `templates/checkpoint-template.json`
- [x] 8.4 Confirm output folder contents against `Invoke-FileAnalysis`'s output-writing steps
- [x] 8.5 Confirm manifest field shape against `templates/queue-manifest-template.json`

## 9. Archive

- [ ] 9.1 Run `openspec archive baseline-system-specs` to move these spec files into `openspec/specs/`
