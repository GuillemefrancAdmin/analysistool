## ADDED Requirements

### Requirement: Fixed nine-agent analysis chain
The analysis pipeline SHALL define exactly nine per-file agent roles, each with a documented `SKILL.md` describing its role, mission, inputs, responsibilities, expected output, and the schema fields it owns, chained in this fixed order: sanitizer-context-ingestion-agent, business-domain-extractor, source-ast-structural-mapper, business-logic-extractor, security-compliance-analyst, performance-scalability-analyst, test-validation-analyst, diagram-designer-context-visualizer, architecture-spec-writer.

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

### Requirement: Architecture-spec-writer owns final schema synthesis
The architecture-spec-writer agent SHALL be the sole stage responsible for producing the final `LegacySourceCodeAnalysisReport`-shaped JSON, consuming domain, structural, logic, security, performance, and test-validation findings (not the diagram output), and owning schema sections including quality metrics, security findings, data lineage, exception handling, test status, business impact, technical debt, ISO 25010 attributes, and modernization recommendations.

#### Scenario: Final stage input excludes the diagram
- **WHEN** the architecture-spec-writer stage runs
- **THEN** its input includes the file path plus the domain, structural, logic, security, performance, and test-validation findings, but not the diagram stage's own output

#### Scenario: Final stage owns cross-cutting schema sections
- **WHEN** the architecture-spec-writer's output is validated against `templates/source-code-analysis-schema.json`
- **THEN** it is the stage responsible for populating `quality_metrics`, `security_findings`, `data_lineage`, `exception_handling`, `test_status`, `business_impact`, `technical_debt_and_code_smells`, `iso_25010_attributes`, and `modernization_recommendations`

### Requirement: File-queue-orchestrator-agent is workflow coordinator, not interpreter
The file-queue-orchestrator-agent SHALL be responsible for discovery, sequencing, checkpointing, and resumption of the per-file queue, and SHALL NOT itself interpret or analyze source code content.

#### Scenario: Orchestrator role boundary
- **WHEN** the file-queue-orchestrator-agent's SKILL.md is reviewed
- **THEN** its documented responsibilities cover discovery/sequencing/state/resumption only, with source interpretation explicitly delegated to the other nine agents
