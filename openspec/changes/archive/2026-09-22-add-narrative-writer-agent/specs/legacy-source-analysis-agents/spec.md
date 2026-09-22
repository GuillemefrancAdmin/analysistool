## MODIFIED Requirements

### Requirement: Fixed nine-agent analysis chain
The analysis pipeline SHALL define exactly ten per-file agent roles, each with a documented `SKILL.md` describing its role, mission, inputs, responsibilities, expected output, and the schema fields or output artifact it owns, chained in this fixed order: sanitizer-context-ingestion-agent, business-domain-extractor, source-ast-structural-mapper, business-logic-extractor, security-compliance-analyst, performance-scalability-analyst, test-validation-analyst, diagram-designer-context-visualizer, narrative-writer, architecture-spec-writer.

#### Scenario: Agent definitions are discoverable
- **WHEN** the `skills/` directory is inspected
- **THEN** exactly one subdirectory with a `SKILL.md` exists per agent name in the fixed chain, plus `file-queue-orchestrator-agent` for queue/state management

## ADDED Requirements

### Requirement: Narrative writer explains file purpose
The narrative-writer agent SHALL consume the same domain, structural, logic, security, performance, and test-validation findings the diagram-designer-context-visualizer agent receives, and SHALL produce prose explaining the source file's purpose — why it exists and what business role it fills — grounded in but not restating the other stages' findings verbatim, as the pipeline's sole owner of the per-file verbose narrative output artifact.

#### Scenario: Narrative writer input composition
- **WHEN** the narrative-writer stage runs
- **THEN** its input includes the outputs of every one of the six preceding analysis stages (domain, structural, logic, security, performance, test-validation), independent of and not dependent on the diagram stage's own output

#### Scenario: Narrative writer owns the verbose description, not the final report
- **WHEN** the architecture-spec-writer's output is validated against `templates/source-code-analysis-schema.json`
- **THEN** the schema has no `markdown_report` field, and the file's verbose narrative exists only as the narrative-writer's own output artifact
