## 1. File index

- [x] 1.1 Iterate `.analysis-state/outputs/**/*.json` (same discovery pattern as `verify_synthesis_quality.ps1`), reading each file's `module_metadata.file_path`.
- [x] 1.2 Build three lookup structures from that set: exact relative path, basename-with-extension (case-insensitive), basename-without-extension (case-insensitive) — each mapping to the list of file paths matching it (so a tier's ambiguity is directly detectable by that list's length).

## 2. File-to-file resolution

- [x] 2.1 For each file's `dependencies_and_integrations.internal_module_dependencies` entries, normalize (trim whitespace, strip surrounding quotes) and attempt resolution through the three tiers in order (exact path, then basename+ext, then basename-only), stopping at the first tier that produces any match. Built via pure string manipulation (`Get-LastPathSegment`/`Remove-LastExtension`), not `Split-Path`/`[System.IO.Path]` methods -- both threw on real dependency strings during testing (`Split-Path` on a bare colon like `"PEAR:DB"`; `Path.GetFileName` on any illegal-filename character anywhere in the string), since those APIs validate/interpret content that's arbitrary LLM-written text, not a trusted path.
- [x] 2.2 Classify each entry as resolved (exactly one match), ambiguous (more than one match, list all candidates), or unresolved (no match at any tier).
- [x] 2.3 Skip self-references (a file naming itself) and empty/placeholder-looking entries rather than counting them as unresolved noise.

## 3. File-to-table aggregation

- [x] 3.1 For each file's `dependencies_and_integrations.database_interactions` entries, group by `target_entity` (case-insensitive grouping key, original casing preserved for display), collecting each contributing file and its `operation_type`.

## 4. Output

- [x] 4.1 Write `.analysis-state/dependency-graph/graph.json`: file-to-file edges (with resolution status) and the file-to-table map, in a shape that's a strict superset of what the summary report needs.
- [x] 4.2 Write/print a human-readable summary: totals (files processed, edges by resolution status, tables found), top N files by fan-in and fan-out (resolved edges only), top N tables by contributing file count.
- [x] 4.3 No manifest/state file access anywhere in the script — verified by grep for `manifest.json`/`.analysis-state/states`/`.analysis-state/queue`: zero code references (only explanatory comments mention them).

## 5. Verification

- [x] 5.1 Run against the live (post-re-run) corpus; sanity-check a handful of resolved edges by hand. Run against the current (pre-full-re-run) corpus, 1578 files: 2038 dependency references (498 resolved, 268 ambiguous, 1272 unresolved), 650 tables found. Top fan-in: `Sigare/bin/system/timestamp.sh` (52 dependents), `lib/c/seterr.sc` (35) -- both immediately recognizable as genuinely shared, load-bearing utilities, real actionable signal.
- [x] 5.2 Sanity-check the ambiguous bucket: confirm it's actually catching real basename collisions, not a resolution-tier bug. Confirmed: sampled ambiguous entries are `Gesacad cobol` vs. `Sigare 4gl` each having their own parallel copy of the same shared COBOL includes (e.g. `global_working_storage.cbl`, `imprime_message_c.cob`) -- a genuine duplicate-library situation across subsystems, correctly flagged rather than guessed, and itself a useful finding for migration planning.
- [x] 5.3 Confirm the run has zero effect on `manifest.json`'s mtime/content and doesn't interfere with a concurrently-running pipeline. Ran twice (including under Windows PowerShell 5.1, confirming no PS7 guard is needed) while the pipeline was actively processing files; `queue_eta.ps1` before/after showed normal progress (1020→1024 completed) with no disruption.
- [x] 5.4 Spot-check the file-to-table map against a file's own `data_lineage.tables_and_entities` for rough consistency. Checked one real file: `database_interactions` (the graph's source) found 2 entities, `tables_and_entities` (broader, less structured) found 5 including the same 2 -- consistent with design expectations (rough overlap, not an exact match requirement), not a wildly different picture.

## Note: two real bugs found and fixed during verification, not anticipated in the original task list

`Split-Path -Leaf` and `[System.IO.Path]::GetFileName`/`GetFileNameWithoutExtension` both crashed the first two runs against real data, because dependency-reference strings are arbitrary LLM-written text that can contain characters those APIs treat as errors (a bare colon; any character in .NET's illegal-filename-character set anywhere in the string) -- neither failure mode showed up in design or code review, only against the real corpus. Replaced with pure string manipulation (`LastIndexOfAny`/`Substring`) that performs no content validation. Worth remembering for any future script that parses filesystem-path-*shaped* text that isn't actually a trusted filesystem path.
