## MODIFIED Requirements

### Requirement: Architecture-spec-writer owns final schema synthesis
The architecture-spec-writer agent SHALL be the sole stage responsible for producing the final `LegacySourceCodeAnalysisReport`-shaped JSON, consuming domain, structural, logic, security, performance, and test-validation findings (not the diagram output), and owning schema sections including quality metrics, security findings, data lineage, exception handling, test status, business impact, technical debt, ISO 25010 attributes, and modernization recommendations. Its synthesized content SHALL be derived from the actual upstream findings provided to it, never from its own prompt's format-template text, and SHALL match the structured shape `templates/source-code-analysis-schema.json` defines for each field — in particular, `functional_requirements` and `technical_debt_and_code_smells` SHALL be arrays of structured objects, not flat delimited strings.

#### Scenario: Final stage input excludes the diagram
- **WHEN** the architecture-spec-writer stage runs
- **THEN** its input includes the file path plus the domain, structural, logic, security, performance, and test-validation findings, but not the diagram stage's own output

#### Scenario: Final stage owns cross-cutting schema sections
- **WHEN** the architecture-spec-writer's output is validated against `templates/source-code-analysis-schema.json`
- **THEN** it is the stage responsible for populating `quality_metrics`, `security_findings`, `data_lineage`, `exception_handling`, `test_status`, `business_impact`, `technical_debt_and_code_smells`, `iso_25010_attributes`, and `modernization_recommendations`

#### Scenario: Synthesized content is never the prompt's own format template
- **WHEN** a source file has zero real findings for a given `functional_requirements` or `technical_debt_and_code_smells` entry
- **THEN** the architecture-spec-writer's output contains an empty array for that field, not a copy of the prompt's placeholder/example text

#### Scenario: functional_requirements and technical_debt_and_code_smells match the schema's structured shape
- **WHEN** the architecture-spec-writer's output is validated against `templates/source-code-analysis-schema.json`
- **THEN** `functional_requirements` and `technical_debt_and_code_smells` are each arrays of structured objects with the schema's required per-item fields (e.g. `requirement_id`, `business_rule_type`), not flat pipe-delimited strings

## ADDED Requirements

### Requirement: Completed files can be re-synthesized without re-running upstream stages
A stage-backfill mechanism SHALL support rewinding already-`completed` files to immediately before a named stage even when that stage has already run for them, using each file's already-saved intermediate outputs from the preceding stages rather than re-running them.

#### Scenario: Re-synthesis rewind targets all completed files regardless of prior stage result
- **WHEN** the backfill mechanism runs against a target stage with the "even if already run" mode enabled
- **THEN** every file with manifest status `completed` is rewound to `last_completed_stage` equal to the stage immediately preceding the target stage, and its status is set back to `queued`, regardless of whether the target stage already has a recorded result for that file

#### Scenario: Re-synthesis reuses saved intermediates instead of re-running upstream stages
- **WHEN** a rewound file is next picked up by a pipeline worker
- **THEN** the worker resumes at the target stage using the preceding stage's already-saved intermediate output, without re-invoking any of the stages before it
