# legacy-source-analysis-agents Specification

## Purpose
TBD - created by archiving change baseline-system-specs. Update Purpose after archive.
## Requirements
### Requirement: Fixed nine-agent analysis chain
The analysis pipeline SHALL define exactly ten per-file agent roles, each with a documented `SKILL.md` describing its role, mission, inputs, responsibilities, expected output, and the schema fields or output artifact it owns, chained in this fixed order: sanitizer-context-ingestion-agent, business-domain-extractor, source-ast-structural-mapper, business-logic-extractor, security-compliance-analyst, performance-scalability-analyst, test-validation-analyst, diagram-designer-context-visualizer, narrative-writer, architecture-spec-writer.

#### Scenario: Agent definitions are discoverable
- **WHEN** the `skills/` directory is inspected
- **THEN** exactly one subdirectory with a `SKILL.md` exists per agent name in the fixed chain, plus `file-queue-orchestrator-agent` for queue/state management

### Requirement: Sanitizer produces the shared base context
The sanitizer-context-ingestion-agent SHALL take raw legacy source (and optional schema/DDL context) and produce a cleaned, schema-enriched context that every downstream stage in the chain consumes, either directly or via a later stage's own output.

#### Scenario: Raw source with an associated schema file
- **WHEN** a source file has a discoverable database schema/DDL association
- **THEN** the sanitizer's output incorporates that schema context alongside the cleaned source, and this sanitized context is what the business-domain-extractor and source-ast-structural-mapper stages receive

### Requirement: Domain and structural analysis run independently off the sanitized context
The business-domain-extractor and source-ast-structural-mapper agents SHALL each consume the sanitizer's output (plus, for the structural mapper, the domain findings) to independently produce business-vocabulary findings and a structural/control-flow map, without needing to re-derive each other's output from raw source.

#### Scenario: Structural mapping uses prior domain findings
- **WHEN** the source-ast-structural-mapper stage runs
- **THEN** its input includes both the sanitized code context and the business-domain-extractor's output from the same file

### Requirement: Business logic extraction combines structure and domain
The business-logic-extractor agent SHALL consume the sanitized context, the structural map, and the domain findings to produce business rules, calculations, validations, and edge-case behavior expressed in testable language.

#### Scenario: Logic extraction input composition
- **WHEN** the business-logic-extractor stage runs
- **THEN** its input includes the sanitized code, the structural breakdown, and the business domain summary from the same file's earlier stages

### Requirement: Security, performance, and test-validation analysts run off structure and logic
The security-compliance-analyst, performance-scalability-analyst, and test-validation-analyst agents SHALL each consume the structural map and business logic findings (the security analyst additionally consuming the sanitized context) to independently produce their respective risk/quality findings.

#### Scenario: Security findings include sanitized-context-derived risks
- **WHEN** the security-compliance-analyst stage runs
- **THEN** its input includes the sanitized code context in addition to the structural breakdown and business logic findings

#### Scenario: Performance and test-validation share the same inputs
- **WHEN** the performance-scalability-analyst and test-validation-analyst stages run
- **THEN** both receive the same structural-breakdown-and-business-logic input, independent of the security findings

### Requirement: Diagram synthesizes all prior findings
The diagram-designer-context-visualizer agent SHALL consume the domain, structural, logic, security, performance, and test-validation findings to produce a single Mermaid (or equivalent) diagram summarizing module structure, dependencies, flow, and risk hotspots.

#### Scenario: Diagram generation input composition
- **WHEN** the diagram-designer-context-visualizer stage runs
- **THEN** its input includes the outputs of every one of the six preceding analysis stages (domain, structural, logic, security, performance, test-validation)

### Requirement: Narrative writer explains file purpose
The narrative-writer agent SHALL consume the same domain, structural, logic, security, performance, and test-validation findings the diagram-designer-context-visualizer agent receives, and SHALL produce prose explaining the source file's purpose — why it exists and what business role it fills — grounded in but not restating the other stages' findings verbatim, as the pipeline's sole owner of the per-file verbose narrative output artifact.

#### Scenario: Narrative writer input composition
- **WHEN** the narrative-writer stage runs
- **THEN** its input includes the outputs of every one of the six preceding analysis stages (domain, structural, logic, security, performance, test-validation), independent of and not dependent on the diagram stage's own output

#### Scenario: Narrative writer owns the verbose description, not the final report
- **WHEN** the architecture-spec-writer's output is validated against `templates/source-code-analysis-schema.json`
- **THEN** the schema has no `markdown_report` field, and the file's verbose narrative exists only as the narrative-writer's own output artifact

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

### Requirement: File-queue-orchestrator-agent is workflow coordinator, not interpreter
The file-queue-orchestrator-agent SHALL be responsible for discovery, sequencing, checkpointing, and resumption of the per-file queue, and SHALL NOT itself interpret or analyze source code content.

#### Scenario: Orchestrator role boundary
- **WHEN** the file-queue-orchestrator-agent's SKILL.md is reviewed
- **THEN** its documented responsibilities cover discovery/sequencing/state/resumption only, with source interpretation explicitly delegated to the other nine agents

### Requirement: Completed files can be re-synthesized without re-running upstream stages
A stage-backfill mechanism SHALL support rewinding already-`completed` files to immediately before a named stage even when that stage has already run for them, using each file's already-saved intermediate outputs from the preceding stages rather than re-running them.

#### Scenario: Re-synthesis rewind targets all completed files regardless of prior stage result
- **WHEN** the backfill mechanism runs against a target stage with the "even if already run" mode enabled
- **THEN** every file with manifest status `completed` is rewound to `last_completed_stage` equal to the stage immediately preceding the target stage, and its status is set back to `queued`, regardless of whether the target stage already has a recorded result for that file

#### Scenario: Re-synthesis reuses saved intermediates instead of re-running upstream stages
- **WHEN** a rewound file is next picked up by a pipeline worker
- **THEN** the worker resumes at the target stage using the preceding stage's already-saved intermediate output, without re-invoking any of the stages before it

