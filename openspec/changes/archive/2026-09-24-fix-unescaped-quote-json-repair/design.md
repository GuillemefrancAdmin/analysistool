## Context

The repair chain (`Remove-CodeFence` → `Repair-JsonEscapes` → `Repair-JsonTruncation`) already handles three distinct failure modes the 8B model produces: prose/fence wrapping, unescaped backslashes (source snippets with regex/sed content), and dropped trailing closers. `Repair-JsonTruncation`'s own approach — walk the text tracking open braces/brackets, skipping over string contents, respecting backslash-escaped characters — is the established pattern for this kind of stateful, context-aware text repair in this codebase.

Investigation of the 11 residual failures found two distinct sub-patterns, not one:
1. A quoted identifier or path embedded verbatim inside a string value (`"trigger_or_invocation": "Called via "SYSTEM" USING /path"`) — the inner `"SYSTEM"` quotes prematurely end the JSON string as far as any parser is concerned.
2. A scalar string field given multiple comma-separated string literals where an array was evidently intended (`"secret_or_credential_usage": "a@b.com", "c@d.com",`) — a container-shape mismatch, not really an "unescaped quote" in the same sense.

## Goals / Non-Goals

**Goals:**
- Reduce future occurrences via a prompt instruction (root-cause fix, cheapest lever).
- Add a best-effort repair heuristic for pattern 1 specifically (embedded quoted substrings), the dominant and more mechanically fixable of the two.

**Non-Goals:**
- Fully solving pattern 2 (wrong container shape) programmatically. Distinguishing "the model meant an array and forgot the brackets" from "the model meant a single string and it happens to contain commas" is not reliably decidable from the text alone; the prompt fix is the primary lever for this sub-pattern, not the repair function.
- General-purpose JSON repair / a real recovering parser. This stays a narrow, targeted heuristic matching this codebase's existing repair-function style, not a rewrite of the parsing approach.
- Changing retry/block behavior — files that still fail after all repairs still retry/block exactly as today.

## Decisions

**`Repair-UnescapedEmbeddedQuotes` is a single-pass character walk, mirroring `Repair-JsonTruncation`'s existing style**, not a regex-only approach: track whether the walk is currently inside a string; on encountering an unescaped `"` while inside one, look ahead past any whitespace — if the next non-whitespace character is `,`, `}`, `]`, or `:`, treat this quote as the real string terminator (matches normal JSON); otherwise, treat it as an embedded quote that should have been escaped, emit `\"` instead, and remain inside the string. This directly targets pattern 1 without needing to understand what the string's content actually means.

**No attempt to fix pattern 2 (comma-separated literals as a malformed array) in the repair function.** Risk of the heuristic guessing wrong (e.g., inserting brackets around a scalar string that genuinely contains a comma, like a sentence) is higher than the value of attempting it — the existing `Repair-JsonTruncation`/`Repair-JsonEscapes` precedent is "safe no-op on already-valid JSON, only kicks in for a specific, narrow, confidently-identified pattern," and pattern 2 doesn't meet that bar. The prompt instruction (task 1 below) is the only lever for this sub-pattern.

**The new repair function slots in after `Repair-JsonEscapes`, before `Repair-JsonTruncation`**, in the existing chain call `(Repair-JsonTruncation (Repair-JsonEscapes (Remove-CodeFence $rawReport)))`. Escaping embedded quotes first means `Repair-JsonTruncation`'s own brace/bracket walk (which already skips over string contents) sees correctly-escaped strings, not ones that still look prematurely terminated.

## Risks / Trade-offs

- **[Risk] The lookahead heuristic can misfire on a real closing quote immediately followed by more prose that happens to start with a comma-like or brace-like character inside subsequent unrelated text** (e.g., a string ending right before a line that starts with a symbol resembling `,`). → Mitigation: same posture as the existing repair functions — "no-op on already-valid JSON" is the design target, not "never wrong on invalid JSON"; a rare misfire on the 1.9%-frequency edge case is still strictly better than today's 100% failure rate for that case (it currently always fails and falls back to retry).
- **[Trade-off] This adds a third stateful text-walk to the repair chain, one more thing to reason about when a file's JSON parsing behaves unexpectedly.** → Accepted, matching how `Repair-JsonTruncation` itself was added for its own narrow failure mode — the chain is explicitly designed to keep growing this way, one targeted repair at a time.

## Migration Plan

None needed — this only affects the repair path for *future* parse failures. No retroactive re-run: the 583 historical instances this was found from already succeeded on retry with no data loss, and are unaffected either way.
