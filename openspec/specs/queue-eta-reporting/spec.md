# queue-eta-reporting Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: Average-based ETA estimation
The ETA reporter SHALL compute the average recorded total elapsed seconds across completed files (those with `status: completed` and a positive recorded elapsed time) and SHALL use that average as the estimate for any remaining file with no stage progress yet.

#### Scenario: No completed files yet
- **WHEN** the manifest has zero files with `status: completed` and a recorded elapsed time
- **THEN** the reporter prints completed/remaining counts but states it cannot estimate an ETA, without dividing by zero

#### Scenario: Some files completed
- **WHEN** at least one file has completed with a recorded elapsed time
- **THEN** the reporter computes the average elapsed time across all such files and uses it as the base per-file estimate

### Requirement: Stage-fraction proration for in-flight files
For a remaining file that already has a recorded `last_completed_stage`, the reporter SHALL prorate its estimate to only the fraction of the nine stages not yet completed, rather than charging the full per-file average.

#### Scenario: File is partway through the chain
- **WHEN** a queued or blocked file's `last_completed_stage` is the 3rd of 9 stages
- **THEN** its remaining-time estimate is 6/9 of the average per-file duration, not the full average

### Requirement: Worker-divided completion estimate
The reporter SHALL divide the total remaining estimated seconds by the effective worker count (`-Workers`, minimum 1) to produce the reported ETA and estimated completion timestamps (UTC and local).

#### Scenario: Single-worker estimate
- **WHEN** the reporter is run with no `-Workers` argument
- **THEN** the ETA is computed assuming exactly 1 worker

#### Scenario: Multi-worker estimate
- **WHEN** the reporter is run with `-Workers 2`
- **THEN** the reported ETA is half of what a single-worker estimate would show for the same remaining work

