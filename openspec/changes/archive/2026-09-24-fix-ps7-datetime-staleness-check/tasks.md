## 1. Root cause confirmation

- [x] 1.1 Reproduce the bug directly: confirm `ConvertFrom-Json` under PS7 auto-converts an ISO-8601 `"...Z"` string to `[datetime]` (`Kind=Utc`), and that `[datetime]::Parse()` on that already-typed value produces a negative elapsed-time result instead of the correct ~3.1 hours.
- [x] 1.2 Audit every other `started_at`/`ended_at`/`last_updated` touch point in `run_analysis_pipeline.ps1` for the same failure class. Confirmed clean: `Set-AgentTiming`'s `[datetime]` parameters are always fresh in-process `Get-Date` values, never parsed from JSON; `Update-ManifestEntry`'s `$dst.started_at = $src.started_at` is a type-agnostic straight property copy; the `-not $state.started_at` check is a simple existence check safe for either type.

## 2. Fix (`scripts/run_analysis_pipeline.ps1`)

- [x] 2.1 In `Request-NextFile`'s staleness check, branch on `-is [datetime]` first (use `.ToUniversalTime()` directly on the already-correctly-typed value) before falling back to `[datetime]::Parse(...)` for the plain-string case.

## 3. Verification

- [x] 3.1 Syntax-check under both Windows PowerShell 5.1 and PowerShell 7.
- [x] 3.2 Unit-test the exact production `Where-Object` pattern against 6 cases (stale/recent × PS7-datetime/string, plus null and non-in_progress) under both engines — all 6 classified correctly in both.
- [x] 3.3 Confirm against the real, currently-affected manifest: both previously-stuck files (`example-repeat.php`, `example-simple.php`, `in_progress` since ~3 hours prior) are now correctly identified as claimable by the fixed logic, read-only (nothing claimed/mutated during the check).

## 4. Spec correction

- [x] 4.1 Rewrite `sequential-pipeline-execution`'s "Multi-worker queue partitioning" requirement, which described a hash-based static partition scheme (`relative-path hash modulo WorkerCount`) that no longer exists in the code (`-WorkerIndex`/`-WorkerCount` are documented in the script itself as cosmetic only) — corrected to describe the actual dynamic per-file atomic-claiming mechanism, and extended with the stale-reclaim and cross-edition-correctness scenarios this change is actually about.
