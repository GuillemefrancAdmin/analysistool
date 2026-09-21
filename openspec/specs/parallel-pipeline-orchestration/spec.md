# parallel-pipeline-orchestration Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: One dedicated Ollama instance per GPU
The parallel orchestrator SHALL start one dedicated `ollama serve` instance per entry in `-OllamaPorts`/`-CudaDevices` (index-matched pairs), pinning each instance to its GPU via `CUDA_VISIBLE_DEVICES` and its own port, and SHALL pre-warm the configured model on each instance before dispatching work to it.

#### Scenario: Default two-GPU launch
- **WHEN** the orchestrator is run with its default two-port/two-device configuration and no instance is currently listening on either port
- **THEN** it starts two separate `ollama serve` processes, each with a distinct `CUDA_VISIBLE_DEVICES` value and port, and waits for each to respond before proceeding

#### Scenario: -NoAutoStart skips instance bootstrap
- **WHEN** the orchestrator is run with `-NoAutoStart`
- **THEN** it assumes a dedicated Ollama instance is already running on each configured port and does not attempt to start one

### Requirement: One worker process per Ollama instance
For each configured Ollama instance, the orchestrator SHALL launch one `run_analysis_pipeline.ps1` worker as a background job, passing that instance's URL and CUDA device along with a distinct `-WorkerIndex` and the shared `-WorkerCount`, so workers partition the queue instead of racing for the same files.

#### Scenario: Worker count matches instance count
- **WHEN** two Ollama instances are configured
- **THEN** exactly two `run_analysis_pipeline.ps1` background jobs are started, with `-WorkerIndex` 0 and 1 and `-WorkerCount` 2

### Requirement: Live output streaming without duplication
While workers run, the orchestrator SHALL poll each job for new output every `-PollSeconds` and print only output arrived since the last poll (no replay of already-seen lines), and SHALL surface a job's terminal-state change (e.g. `Failed`/`Stopped`) and its failure reason at most once.

#### Scenario: One worker fails mid-run
- **WHEN** one worker's job transitions to `Failed` while the other is still `Running`
- **THEN** the orchestrator prints that job's failure reason once, continues streaming the still-running worker's output, and does not repeat the failure line on subsequent polls

### Requirement: Periodic ETA reporting during a parallel run
While workers are running, the orchestrator SHALL invoke the ETA reporter against the shared manifest at least every `-EtaEverySeconds`, passing the total worker count so the estimate reflects concurrent processing.

#### Scenario: Long-running parallel job
- **WHEN** a parallel run continues for longer than `-EtaEverySeconds`
- **THEN** an ETA report is printed reflecting live manifest state, divided across the configured worker count

### Requirement: Run-completion summary
After all worker jobs reach a terminal state, the orchestrator SHALL report each worker's final job state, print the failure reason for any worker that failed, and print a final ETA/progress summary against the manifest.

#### Scenario: All workers complete successfully
- **WHEN** every worker job finishes with state `Completed`
- **THEN** the summary lists each worker as `Completed` and prints a final progress report with no failure lines

