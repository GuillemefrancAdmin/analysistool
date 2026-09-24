## Why

Investigating a rise in `.raw.txt` orphaned files after this session's `complete-architecture-spec-schema-coverage` and `fix-unescaped-quote-json-repair` changes landed (37 → 59 across one corpus-wide rerun) found the new failures aren't the unescaped-quote pattern either of those changes targeted. Direct inspection of the raw model output confirms a distinct, previously-unseen syntax error: the model occasionally closes an **object** with `]` instead of `}` (or, presumably, the reverse) on `dependencies_and_integrations` — a field whose shape is an object containing a mix of string arrays, object arrays (`database_interactions`, `external_library_dependencies`), and a trailing boolean (`integration_ceiling_risk`). Concretely, in one real failing file:

```
"dependencies_and_integrations": {
    "internal_module_dependencies": [],
    "external_library_dependencies": [],
    "database_interactions": [
      { ... }, { ... }, { ... }
    ],
    "network_and_api_calls": [],
    "integration_ceiling_risk": false
  ],
```

The final `]` should be `}`. The most plausible explanation: after generating the deeply-nested `database_interactions` array-of-objects, the model's closing-bracket pattern-completion habit favors `]` and it loses track that the *outer* container (`dependencies_and_integrations` itself) needs `}`, not the array it just finished. `ConvertFrom-Json` reports this as `"JsonToken EndArray is not valid for closing JsonType Object"`.

A secondary, related issue spotted in the same block: an invalid enum value (`"operation_type": "SELECT"`, not in the schema's `READ|WRITE|UPDATE|DELETE|SCHEMA_DDL|STORED_PROCEDURE_EXEC` list) — semantically wrong but not a JSON syntax break, so it's a `Test-Json`-detectable schema issue rather than a parse failure. Worth a mention in the same prompt-reinforcement pass, but the parse-breaking bracket mismatch is this change's primary target.

## What Changes

- Add `Repair-MismatchedContainerClosers` to the repair chain: extends the same open-container-stack tracking `Repair-JsonTruncation` already does (walk the text, push on `{`/`[`, pop on `}`/`]`, skip string contents) to also catch a **closer whose bracket type doesn't match what's actually open** at that point, and correct it to match the stack — rather than only handling *missing* closers (Repair-JsonTruncation's current scope) or *extra unescaped characters* (the other repair functions' scope).
- Add a short prompt reinforcement: an explicit reminder that each container's closing bracket must match its own opening bracket type, regardless of what was most recently closed inside it — placed near the existing anti-echo/enum-conformance instructions.
- Reinforce that `database_interactions.operation_type` (and other enum fields) must come from the schema's own enum list, addressing the observed `"SELECT"` case as a concrete example of the general enum-conformance instruction already added by `complete-architecture-spec-schema-coverage`.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `legacy-source-analysis-agents`: extends the "architecture-spec-writer output survives known non-JSON artifacts" requirement (added by `fix-unescaped-quote-json-repair`) to cover mismatched container closers as another known, repaired artifact class.

## Impact

- `scripts/run_analysis_pipeline.ps1`: new repair function, inserted into the existing chain; small prompt addition.
- No schema change. No retroactive re-run included in this proposal — sizing how common this failure actually is (beyond the small sample found so far) is worth doing before committing to another full-corpus pass; left as an implementation-time decision alongside the `harden-manifest-against-bitflip-corruption` change, which may be worth landing and re-running together.
