## MODIFIED Requirements

### Requirement: Manifest is the live, mutable index
`.analysis-state/queue/manifest.json` SHALL be the single mutable index of all tracked files and their status, safe for concurrent read by reporting tools (`queue_eta.ps1`) and concurrent read-modify-write by multiple pipeline workers, via the write safety and locking behavior defined in `source-discovery-queue` and `sequential-pipeline-execution`. Readers of the manifest SHALL additionally attempt to auto-repair known, narrow corruption patterns before falling back to their existing retry/failure behavior: first, a small number of non-ASCII characters appearing in raw JSON structural whitespace (since the manifest's own content is always plain ASCII, any such character is reliably corruption); and if that doesn't apply or doesn't succeed, a bounded search for a single-bit-flip-plausible character substitution near the parse failure's reported location.

#### Scenario: Manifest reflects current queue state at any time
- **WHEN** the manifest is read at any point during or between runs
- **THEN** it lists every discovered file with its current `status`, `last_completed_stage`, and `token_usage`, consistent with each file's own state file

#### Scenario: A known stray-character corruption is repaired transparently
- **WHEN** a manifest read fails to parse as JSON, and the raw content contains five or fewer characters outside the normal ASCII range
- **THEN** the reader replaces those characters and retries parsing once before falling back to its normal retry/failure behavior, and if the repaired content parses successfully, the read succeeds using the repaired content without the caller needing to handle the failure

#### Scenario: A single-bit-flip-style character substitution is repaired transparently
- **WHEN** a manifest read fails to parse as JSON, the non-ASCII repair doesn't apply or doesn't succeed, and a bounded search near the parse failure's reported location finds a single-bit-flip variant of some nearby character that makes the entire document parse successfully
- **THEN** the reader uses that repaired content, within a bounded number of search attempts, without the caller needing to handle the failure

#### Scenario: An unfamiliar or larger-scale corruption is not silently guessed at
- **WHEN** a manifest read fails to parse as JSON, and neither the non-ASCII repair nor the bounded bit-flip search (within its attempt budget) produces content that parses successfully
- **THEN** the reader does not accept a guessed repair, and falls through to its existing retry-then-throw behavior instead
