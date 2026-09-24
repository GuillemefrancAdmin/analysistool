## Context

`Repair-JsonTruncation` already walks the full text tracking a stack of expected closers (pushes `}`/`]` on `{`/`[`, skips string contents respecting backslash escapes) — but its current pop logic (`if ($stack.Count -gt 0) { [void]$stack.Pop() }`) doesn't check whether the closer it just saw actually matches what it expected; it just decrements depth. That's sufficient for its own job (append whatever's left on the stack at EOF), but means it silently tracks past a bracket-type mismatch in the *middle* of the document without ever correcting it — the wrong character stays exactly where it was, so the document still fails to parse.

The real observed case: `dependencies_and_integrations` (an object) closes with `]` after its last real field (`database_interactions`, an array of objects) — the model's closing-bracket habit favors repeating the type it just finished with, rather than correctly returning to the *outer* container's own type.

## Goals / Non-Goals

**Goals:**
- Detect a closer whose bracket type doesn't match the stack's expected type, and correct it in place (swap the wrong character for the right one), reusing the exact stack-tracking approach already proven in `Repair-JsonTruncation`.
- Keep this a no-op on already-valid JSON, same posture as every other repair function in the chain.

**Non-Goals:**
- Rewriting `Repair-JsonTruncation` itself to also do in-place correction — kept as a separate new function (matching this session's established pattern of one narrow function per narrow failure class, e.g. `Repair-UnescapedEmbeddedQuotes` alongside `Repair-JsonEscapes` rather than merged into it).
- Handling more exotic structural corruption (e.g. a closer appearing with no corresponding opener at all, or multiple simultaneous mismatches implying a deeper structural problem) — if the stack underflows or the correction still doesn't yield parseable JSON, this function's output is still expected to fail parsing and fall through to the existing retry/block behavior, same as any repair chain member today.
- A retroactive corpus-wide re-run as part of this change — sizing actual prevalence first (task list) determines whether that's worth it, decided during implementation rather than committed to upfront.

## Decisions

**New `Repair-MismatchedContainerClosers` function, not a change to `Repair-JsonTruncation`.** Same stack-tracking walk, but this one is a *building*, in-place-correcting pass: track the stack the same way, and on each `}`/`]` encountered, compare it against `$stack.Peek()` (not blind-pop) — if it matches, pop and emit the character unchanged; if it doesn't match, emit the *expected* closer instead (correcting the mismatch) and pop. Builds a new string via `StringBuilder` rather than mutating in place, matching `Repair-UnescapedEmbeddedQuotes`'s existing style in this same file.

**Runs before `Repair-JsonTruncation` in the chain**, not after: `Repair-JsonTruncation`'s own stack-walk is unaffected either way (it doesn't care whether closers were type-correct historically, only current depth), but correcting mismatches first means any container that was *only* missing its type-correct closer (not genuinely truncated) won't also trigger `Repair-JsonTruncation`'s EOF-append logic unnecessarily.

**Prompt reinforcement is a single added sentence, not a schema/shape rewrite.** The existing bracketed-placeholder-token format template already shows the correct shape; the failure is closing-bracket *discipline* during generation, which is a instruction-following problem, not a shape-comprehension problem — matching how `complete-architecture-spec-schema-coverage`'s enum-conformance fix was also a single added sentence, not new schema examples.

## Risks / Trade-offs

- **[Risk] If a document has more than one mismatch, or a mismatch nested inside another already-broken structure, blindly trusting the stack's "expected" type at each point could produce a document that's structurally balanced but semantically wrong (e.g. swapping in `}` where the model actually meant to open a *new* array a level up).** → Mitigation: same posture as every other repair function here — the output still has to pass `ConvertFrom-Json` before being accepted; a wrong correction just means the file still fails to parse and falls through to retry/block, not a silent acceptance of corrupted data.
- **[Trade-off] Adds a fourth stateful text-walk to the repair chain.** → Accepted, consistent with how this chain has grown (`Repair-UnescapedEmbeddedQuotes` was the third); each addition targets one narrow, empirically-confirmed failure class.

## Migration Plan

None required by this change alone. Whether to run a retroactive backfill+re-run (same mechanism as prior fixes this session) is an implementation-time decision, informed by task 3's prevalence measurement — possibly worth bundling with `harden-manifest-against-bitflip-corruption`'s own changes into one combined re-run rather than yet another separate full-corpus pass.

## Open Questions

- Exact prevalence of this failure across the corpus — not yet measured beyond the handful of `.raw.txt` samples found. First implementation task.
- Whether the `"SELECT"` enum-violation observation warrants its own dedicated fix beyond the existing general enum-conformance instruction, or whether that instruction (already shipped) is expected to cover it — worth re-measuring after this fix's prompt reinforcement lands, using the same `Test-Json` machinery `verify_synthesis_quality.ps1` already has.
