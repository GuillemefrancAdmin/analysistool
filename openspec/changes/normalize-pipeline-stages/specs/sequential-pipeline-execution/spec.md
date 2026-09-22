## MODIFIED Requirements

### Requirement: One-file-at-a-time stage chain
The pipeline runner SHALL process each queued file through the ordered list of stages defined by the shared stage registry (see `pipeline-stage-registry`), calling a local Ollama OpenAI-compatible endpoint for each stage, and SHALL feed each stage's output forward as context to later stages according to each stage's own declared input composition (e.g. the diagram and narrative stages each independently receive domain, structural, logic, security, performance, and test findings, and the final stage receives that same set, not the diagram or narrative output).

#### Scenario: Full run on a fresh file
- **WHEN** `run_analysis_pipeline.ps1` processes a file with no prior state
- **THEN** every stage in the shared registry's order runs in sequence, each stage's output is saved as an intermediate, and a final structured report is produced

#### Scenario: -Limit controls batch size
- **WHEN** the script is invoked with `-Limit 5`
- **THEN** at most 5 eligible files are processed in that run, leaving the rest of the queue untouched

#### Scenario: -DryRun shows the plan without calling the model
- **WHEN** the script is invoked with `-DryRun`
- **THEN** it lists which files would be processed and their resume point, and makes no Ollama calls
