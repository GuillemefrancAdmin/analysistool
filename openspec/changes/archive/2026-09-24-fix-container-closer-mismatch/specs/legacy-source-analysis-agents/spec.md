## MODIFIED Requirements

### Requirement: Architecture-spec-writer output survives known non-JSON artifacts before parsing
The pipeline SHALL repair known, narrow classes of non-JSON artifacts in architecture-spec-writer's raw output — markdown code fences and prose preface, unescaped backslashes in echoed source snippets, unescaped double-quotes embedded inside a string value, a closing bracket whose type doesn't match its own opening container, and missing trailing closing braces/brackets — before attempting to parse the output as JSON, rather than treating any one of these as an immediate, unrecoverable parse failure.

#### Scenario: Embedded quoted identifier is repaired before parsing
- **WHEN** the raw output contains a string value with an unescaped double-quote around an embedded identifier or path (e.g. a quoted variable name or file path copied verbatim from the source file)
- **THEN** the repair chain escapes it before the result is parsed, rather than the file failing JSON parsing and falling back to retry/block for that reason alone

#### Scenario: Mismatched container closer is corrected before parsing
- **WHEN** the raw output closes an object with `]` (or an array with `}`) instead of the closer matching its own opening bracket — e.g. after a nested array-of-objects field, the model's next closing bracket repeats the array type instead of returning to the enclosing object's type
- **THEN** the repair chain corrects the closer to match what's actually open at that point before the result is parsed, rather than the file failing JSON parsing for that reason alone

#### Scenario: Repair is a no-op on already-valid JSON
- **WHEN** architecture-spec-writer's raw output is already well-formed JSON with no embedded-quote or mismatched-closer artifacts
- **THEN** the repair chain returns it unchanged
