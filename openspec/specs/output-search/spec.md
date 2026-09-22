# output-search Specification

## Purpose
TBD - created by archiving change web-output-viewer. Update Purpose after archive.
## Requirements
### Requirement: Full-text search across analysis outputs
The viewer SHALL provide a search interface that performs full-text search across all completed files' `<file>.md` narrative content and `<file>.json` textual fields (e.g. `primary_purpose`, requirement `description`, security finding descriptions, modernization plan steps), returning ranked results that link to each matching file's detail page.

#### Scenario: Free-text search finds a matching file
- **WHEN** a user searches for a keyword that appears in a completed file's markdown narrative or JSON textual fields
- **THEN** that file appears in the search results, linked to its detail page

#### Scenario: Search with no matches
- **WHEN** a user searches for a term that appears in no analyzed file
- **THEN** the search UI shows an empty-results state rather than an error

### Requirement: Structured/faceted filtering on report fields
The search interface SHALL support filtering results by structured fields present in the JSON schema, including at minimum: technical debt `severity`, functional requirement `business_rule_type`, `modernization_recommendations.recommended_7r_strategy`, and `business_impact.criticality_level`.

#### Scenario: Filtering by severity
- **WHEN** a user filters search results to `severity: critical`
- **THEN** only files containing at least one technical-debt or security finding recorded as `critical` are shown

#### Scenario: Combining free text and a facet filter
- **WHEN** a user enters a free-text search term and also applies a structured filter (e.g. `recommended_7r_strategy: Rearchitect`)
- **THEN** results satisfy both the text match and the filter condition

### Requirement: Search index stays current with pipeline output
The system SHALL keep its search index synchronized with `.analysis-state/outputs/` and `.analysis-state/queue/manifest.json` while the viewer server is running, via filesystem change detection, and SHALL also provide a manual reindex action as a fallback.

#### Scenario: New file becomes searchable after completion
- **WHEN** the pipeline completes analysis of a new file while the viewer is running
- **THEN** that file's content becomes findable via search without restarting the viewer server

#### Scenario: Manual reindex fallback
- **WHEN** a user triggers the manual reindex action
- **THEN** the search index is rebuilt from the current contents of `.analysis-state/outputs/` and `manifest.json`, and subsequent searches reflect that rebuilt index

### Requirement: Search excludes incomplete or invalid reports from indexed content
The search index SHALL only index textual content from files with a valid, parsed `<file>.json` or `<file>.md`; files with status other than `completed`, or with unparseable output, SHALL be excluded from full-text indexing (though they may still appear in the overview list per `output-web-viewer`).

#### Scenario: Blocked file is not returned by content search
- **WHEN** a user searches for a term that only appears in a blocked file's raw/unparsed output
- **THEN** that file does not appear in the search results (it remains visible via the overview page's status listing)
