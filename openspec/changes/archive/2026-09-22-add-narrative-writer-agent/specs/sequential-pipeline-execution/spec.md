## MODIFIED Requirements

### Requirement: One-file-at-a-time stage chain
The pipeline runner SHALL process each queued file through ten agent stages in fixed order (`sanitizer_context_ingestion_agent`, `business_domain_extractor`, `source_ast_structural_mapper`, `business_logic_extractor`, `security_compliance_analyst`, `performance_scalability_analyst`, `test_validation_analyst`, `diagram_designer_context_visualizer`, `narrative_writer`, `architecture_spec_writer`), calling a local Ollama OpenAI-compatible endpoint for each stage, and SHALL feed each stage's output forward as context to later stages according to the documented chain (e.g. the diagram and narrative stages each independently receive domain, structural, logic, security, performance, and test findings, and the final stage receives that same set, not the diagram or narrative output).

#### Scenario: Full run on a fresh file
- **WHEN** `run_analysis_pipeline.ps1` processes a file with no prior state
- **THEN** all ten stages run in order, each stage's output is saved as an intermediate, and a final structured report is produced

#### Scenario: -Limit controls batch size
- **WHEN** the script is invoked with `-Limit 5`
- **THEN** at most 5 eligible files are processed in that run, leaving the rest of the queue untouched

#### Scenario: -DryRun shows the plan without calling the model
- **WHEN** the script is invoked with `-DryRun`
- **THEN** it lists which files would be processed and their resume point, and makes no Ollama calls

### Requirement: Structured final report output
The final stage (`architecture_spec_writer`) SHALL produce a JSON report conforming to the flattened `LegacySourceCodeAnalysisReport` shape; on successful parse, the runner SHALL write the JSON report and mark the file `completed`; on a parse failure, it SHALL save the raw output, mark the file `blocked`, and record a retry-from-final-stage next action. The file's verbose Markdown narrative is written independently by the `narrative_writer` stage, not by `architecture_spec_writer`.

#### Scenario: Final stage produces valid JSON
- **WHEN** the architecture-spec-writer stage's output parses as valid JSON
- **THEN** a `<file>.json` report is written to the file's output directory and the file's status becomes `completed`

#### Scenario: Final stage produces invalid JSON
- **WHEN** the architecture-spec-writer stage's output does not parse as valid JSON
- **THEN** the raw text is saved to `<file>.raw.txt`, the file's status becomes `blocked`, and `next_action` is set to retry from the final stage

#### Scenario: Narrative stage writes its own artifact independent of the final stage's outcome
- **WHEN** the narrative-writer stage completes, regardless of whether the later architecture-spec-writer stage's JSON subsequently parses successfully
- **THEN** a `<file>.md` narrative is written to the file's output directory
