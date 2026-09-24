## Why

Investigating `.analysis-state/outputs/`'s 583 orphaned `*.raw.txt` files (leftover debris from failed `architecture_spec_writer` attempts that all eventually succeeded on retry, during `fix-architecture-spec-synthesis`) found that ~98% predated the existing `Repair-JsonEscapes`/`Repair-JsonTruncation` repair chain and now parse fine against it. The remaining 11/583 (1.9%) still fail even against current repair logic, for a genuinely different, narrower reason: the model emits **unescaped double-quote characters embedded inside a JSON string value** — either a raw source-code fragment quoted verbatim (`"SYSTEM" USING "/path/to/script.sh"`), or a comma-separated list of string literals written where a JSON array was intended (`"a@b.com", "c@d.com",`). Neither of the existing repair functions touches this (`Repair-JsonEscapes` only doubles stray backslashes; `Repair-JsonTruncation` only appends missing closing braces/brackets).

This is a small, low-volume, non-blocking issue today (every historical instance succeeded on retry — the pipeline already recovers from it, just wastefully, by re-running the whole stage and hoping for different output). It's being written up now, while the finding is fresh, for you to pick up whenever convenient.

## What Changes

- Add an explicit instruction to `$ArchitectureSpecSystemPrompt` telling the model to escape any double-quote character that appears *inside* a JSON string value (quoted identifiers, file paths, or source snippets being echoed), rather than leaving it unescaped — the root-cause-level fix, same philosophy as this session's other prompt reliability fixes.
- Add a best-effort `Repair-UnescapedEmbeddedQuotes` function to the existing repair chain (`Remove-CodeFence` → `Repair-JsonEscapes` → `Repair-JsonTruncation` → this), as a backstop for whatever the prompt fix doesn't fully eliminate. Explicitly **not** a general JSON repair — a targeted heuristic for the specific pattern observed (a `"..."` span containing an inner `"word"`-shaped quoted substring immediately followed by more string content, where a real string terminator would instead be followed by `,`/`}`/`]`/`:`).
- No change to what triggers a retry — this only widens what the repair chain can successfully recover before falling back to a retry/block.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `legacy-source-analysis-agents`: gains a new requirement documenting that architecture-spec-writer's raw output survives known non-JSON artifacts (fences, prose, bad backslashes, embedded quotes, truncation) via a repair chain before parsing, rather than any one of them being an unrecoverable parse failure — this repair behavior existed already for the first three artifact classes; this change extends it to embedded quotes and is the first time it's captured as a spec requirement at all.

## Impact

- `scripts/run_analysis_pipeline.ps1`: one new instruction sentence in `$ArchitectureSpecSystemPrompt`; one new `Repair-UnescapedEmbeddedQuotes` function, inserted into the existing repair pipeline call chain.
- No manifest/schema/spec changes. No retroactive re-run needed on its own — this only affects future parse failures, and the 583 historical instances it was found from already succeeded on retry with no data loss.
