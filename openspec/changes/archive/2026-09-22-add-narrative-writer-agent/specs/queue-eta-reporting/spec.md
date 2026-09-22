## MODIFIED Requirements

### Requirement: Stage-fraction proration for in-flight files
For a remaining file that already has a recorded `last_completed_stage`, the reporter SHALL prorate its estimate to only the fraction of the ten stages not yet completed, rather than charging the full per-file average.

#### Scenario: File is partway through the chain
- **WHEN** a queued or blocked file's `last_completed_stage` is the 3rd of 10 stages
- **THEN** its remaining-time estimate is 7/10 of the average per-file duration, not the full average
