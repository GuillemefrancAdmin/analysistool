## ADDED Requirements

### Requirement: Total token consumption reporting
The ETA reporter SHALL report total tokens consumed across all manifest files with recorded token usage, broken down into prompt tokens, completion tokens, and their combined total.

#### Scenario: Corpus with recorded token usage
- **WHEN** the manifest has at least one file with a recorded `total_tokens` value for any stage
- **THEN** the reporter prints the summed prompt tokens, summed completion tokens, and their combined total across the whole manifest

#### Scenario: No token usage recorded yet
- **WHEN** no file in the manifest has any recorded token usage
- **THEN** the reporter states it has no token data yet, without dividing by zero or printing misleading zero-valued statistics as if they were real measurements

### Requirement: Per-stage token statistics
The ETA reporter SHALL compute, for each stage in the shared stage registry, the average tokens per file and the total tokens consumed so far, drawn only from samples recorded for that specific stage — using the same per-stage sample-averaging approach already used for per-stage elapsed-seconds estimation, not a blended full-chain average.

#### Scenario: Stage with recorded samples
- **WHEN** at least one manifest file has a recorded `total_tokens` value for a given stage
- **THEN** the reporter prints that stage's average tokens per file and its total tokens consumed, computed only from files with a sample for that specific stage

#### Scenario: Stage with no recorded samples yet
- **WHEN** a stage (e.g. a newly-added one) has no file with a recorded token sample for it
- **THEN** the reporter does not print a fabricated per-stage token figure for that stage

### Requirement: Per-stage throughput reporting
The ETA reporter SHALL report each stage's average generation throughput as the sum of that stage's completion tokens divided by the sum of that stage's elapsed seconds across all its samples, not prompt or total tokens, and not an average of per-sample ratios.

#### Scenario: Stage throughput calculation
- **WHEN** a stage has multiple recorded samples with varying elapsed times and completion-token counts
- **THEN** the reported throughput for that stage equals the sum of all its samples' completion tokens divided by the sum of all its samples' elapsed seconds

### Requirement: Token-based remaining-queue projection
The ETA reporter SHALL project total tokens for the remaining queue by summing, for each remaining file, its yet-to-run stages' average token counts from its `last_completed_stage` onward — mirroring the existing time-based remaining-seconds proration — rather than a blended per-file average token count.

#### Scenario: Projection for a partially-completed file
- **WHEN** a queued or blocked file's `last_completed_stage` is the 3rd of 10 stages
- **THEN** its projected remaining token count sums only the average token counts of stages 4 through 10, not all 10 stages' averages

### Requirement: Per-model token breakdown
The ETA reporter SHALL report a per-model breakdown of token consumption only when more than one distinct `model_name` appears across the recorded samples, and SHALL omit this breakdown when the samples reflect a single model.

#### Scenario: Single-model corpus
- **WHEN** every recorded sample's `model_name` is the same value
- **THEN** the reporter does not print a per-model breakdown section

#### Scenario: Multi-model corpus
- **WHEN** recorded samples include more than one distinct `model_name` value
- **THEN** the reporter prints a per-model breakdown showing each model's total token consumption
