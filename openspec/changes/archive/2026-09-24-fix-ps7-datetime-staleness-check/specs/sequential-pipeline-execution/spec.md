## MODIFIED Requirements

### Requirement: Multi-worker queue partitioning
Each worker SHALL claim its next file by atomically selecting one eligible entry from the shared manifest at the moment it becomes idle — first any `queued`/`blocked` file, or if none, any `in_progress` file whose `last_updated` is stale (older than `-StaleInProgressSeconds`) — rather than being assigned a fixed subset up front, so a worker that finishes faster than its peers immediately helps with whatever's left instead of exiting once a pre-assigned slice is done. `-WorkerIndex`/`-WorkerCount` are cosmetic only (log tag/color, lock-file metadata) and do not affect which files a worker is eligible to claim.

#### Scenario: A faster worker helps with the rest of the queue
- **WHEN** one worker finishes its current file while another worker is still processing a larger file
- **THEN** the free worker immediately claims the next eligible file from the shared queue rather than waiting or exiting

#### Scenario: Stale in_progress file reclaimed by a different worker
- **WHEN** an `in_progress` file's `last_updated` is older than the configured staleness threshold (e.g. its owning worker crashed outright, with nothing in-script able to mark it `blocked`)
- **THEN** any worker that next becomes idle SHALL claim that file and resume it from its `last_completed_stage`, regardless of which worker originally claimed it

#### Scenario: Staleness comparison is correct regardless of PowerShell edition
- **WHEN** a manifest entry's `last_updated` value is read back via `ConvertFrom-Json`, which may return either a plain string (Windows PowerShell 5.1) or an already-parsed `[datetime]` value (PowerShell 7's auto-conversion of ISO-8601 strings)
- **THEN** the staleness comparison produces the same, correct elapsed-time result in either case, never silently misinterpreting an already-typed UTC value as local time
