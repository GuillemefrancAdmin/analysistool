# Drives the 9-skill legacy-source analysis pipeline (skills/*) against the
# queue built by generate_analysis_queue.ps1, calling a local Ollama model
# directly (OpenAI-compatible /v1/chat/completions) for each stage. Progress,
# per-agent token usage, and resume position are persisted in each file's
# .analysis-state/states/*.state.json record after every stage, so a run can
# be interrupted and continued without redoing completed stages.
#
# IMPORTANT SCHEMA NOTE: templates/source-code-analysis-schema.json requires
# several array-of-OBJECT fields (functional_requirements[], etc.). Grammar-
# constrained structured output on a local model reliably hangs on nested
# array-of-objects (this is why the old run_legacy_doc.ps1 flattened its own
# output schema). This script asks the final "architecture_spec_writer"
# stage for the same conceptual sections but with those specific fields
# flattened to descriptive strings, and parses the result as plain JSON
# (no response_format/grammar constraint) so a slow/failed grammar compile
# can't hang the call. See $ArchitectureSpecSystemPrompt below for the exact
# shape produced.
#
# Usage:
#   .\run_analysis_pipeline.ps1                      # process 1 queued file
#   .\run_analysis_pipeline.ps1 -Limit 5             # process up to 5 files
#   .\run_analysis_pipeline.ps1 -Limit 0             # process the entire remaining queue
#   .\run_analysis_pipeline.ps1 -DryRun              # show what would be picked, call nothing
#   .\run_analysis_pipeline.ps1 -Model "qwen2.5-coder:32b"
#
#   Running multiple workers in parallel against the same queue, one per
#   GPU: Ollama pins a whole server *process* to a GPU via CUDA_VISIBLE_
#   DEVICES at launch (unlike LM Studio, which can't guarantee physical GPU
#   placement per model identifier), so each worker needs its own port and
#   CUDA device. There's no fixed per-worker slice of the queue -- every
#   worker atomically claims its next file from the shared manifest as it
#   goes (see Request-NextFile), so a worker that finishes faster than its
#   peers immediately helps with whatever they haven't gotten to yet instead
#   of exiting. -WorkerIndex/-WorkerCount only affect this worker's own log
#   tag/color and its lock-file metadata. Two terminals:
#     .\run_analysis_pipeline.ps1 -Limit 0 -OllamaUrl http://127.0.0.1:11435/v1 -CudaVisibleDevices 1 -WorkerIndex 0 -WorkerCount 2
#     .\run_analysis_pipeline.ps1 -Limit 0 -OllamaUrl http://127.0.0.1:11436/v1 -CudaVisibleDevices 0 -WorkerIndex 1 -WorkerCount 2
#   (run_analysis_pipeline_parallel.ps1 does this automatically.)
#
# When to use: to run or resume the analysis itself. One worker at a time --
# with several GPUs use run_analysis_pipeline_parallel.ps1 instead, which
# launches this script per worker. Stop a run with stop_analysis_pipeline.ps1.

param(
    [int]$Limit = 1,
    [string]$OllamaUrl = "http://localhost:11434/v1",
    [string]$Model = "llama3.1:8b",
    [double]$Temperature = 0.2,
    # 0 would leave max_tokens unset, letting a stage that never emits a stop
    # token run all the way to the model's context limit -- observed in
    # practice as a single stage stuck "still working" for over an hour on an
    # 8-line input. Real stage outputs run a few hundred to ~2k tokens, so
    # 4096 leaves headroom without allowing that runaway.
    [int]$MaxTokensPerStage = 4096,
    [int]$TimeoutSec = 86400,
    [int]$MaxContentChars = 0,
    [int]$MaxFinalContextChars = 160000,
    [switch]$DryRun,
    # Purely cosmetic/identifying now (log tag+color, lock-file metadata):
    # workers no longer partition the queue by these -- see Request-NextFile.
    [int]$WorkerIndex = 0,
    [int]$WorkerCount = 1,
    # An in_progress file is claimable by ANY worker once idle this long,
    # which is what lets a file abandoned by a worker that crashed outright
    # (e.g. the clr.dll access violation case, where nothing in-script gets
    # a chance to mark it blocked) get picked back up by whichever worker is
    # next free, resuming from its last completed stage -- rather than
    # sitting stuck until that exact same (now-dead) worker comes back.
    [int]$StaleInProgressSeconds = 300,
    # Stall guard: a file's total budget is StallMultiplier times this
    # worker's own average seconds/file (falling back to the queue-wide
    # average, then BootstrapFileSeconds, until this worker has completed
    # at least one file itself). Exceeding that budget mid-file is treated
    # as a stall: the model is unloaded via `ollama stop` (it lazy-loads
    # again on the next request) and the file is retried once with
    # StallRetryMarginSeconds of extra budget. A second stall on the same
    # file gives up and blocks it as usual.
    [double]$StallMultiplier = 4.0,
    [int]$StallRetryMarginSeconds = 300,
    [int]$MinStageTimeoutSeconds = 30,
    [double]$BootstrapFileSeconds = 300,
    # Recovery for when Ollama itself stops answering mid-call (its process
    # crashed or reset the connection -- e.g. "Ollama HTTP 500 ... forcibly
    # closed"), as opposed to this worker's own stall-budget timing out.
    # Rather than blocking the file after one failure, wait this long for
    # Ollama to settle, restart the instance/model, and retry -- up to
    # -OllamaDownMaxRetries times before finally giving up and blocking.
    [int]$OllamaDownWaitSeconds = 300,
    [int]$OllamaDownMaxRetries = 12,
    # If -OllamaUrl isn't reachable, start a dedicated `ollama serve`
    # instance for it and pre-warm -Model before giving up.
    # -CudaVisibleDevices empty means "don't manage GPU pinning, assume
    # whatever's already running on this port" (manual/standalone use).
    [switch]$NoAutoStart,
    [string]$CudaVisibleDevices = "",
    [string]$OllamaModelsPath = "E:\ollama\models",
    # While a stage's Ollama call is in flight, print a "... still
    # working (Ns)" line via Log every this-many seconds, so a long stage
    # doesn't look indistinguishable from a hung one.
    [int]$HeartbeatSeconds = 5
)

# Relaunch under PowerShell 7 when available -- see pipeline_common.ps1 for why
# (manifest.json outgrows Windows PowerShell 5.1's parser) and how the parameter
# forwarding works. A no-op when this is already running under PS7, including
# when launched as a worker job by an already-relaunched orchestrator.
. (Join-Path $PSScriptRoot "pipeline_common.ps1")
Restart-UnderPowerShell7 -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$Root = Split-Path -Parent $PSScriptRoot
$StateRoot = Join-Path $Root ".analysis-state"
$QueueDir = Join-Path $StateRoot "queue"
$CheckpointsDir = Join-Path $StateRoot "checkpoints"
$OutputsDir = Join-Path $StateRoot "outputs"
$StatesDir = Join-Path $StateRoot "states"
$StatesDoneDir = Join-Path $StatesDir "done"
$StatesBlockedDir = Join-Path $StatesDir "blocked"
$ManifestPath = Join-Path $QueueDir "manifest.json"
$LocksDir = Join-Path $StateRoot "locks"

# Register this run so reset_analysis_state.ps1 can find and stop it before
# wiping .analysis-state out from under a still-running process. One lock
# file per PID -- in parallel mode each worker is its own process with its
# own lock; the orchestrator itself needs none since killing its workers
# makes its polling loop exit on its own.
if (-not (Test-Path -LiteralPath $LocksDir)) { New-Item -ItemType Directory -Path $LocksDir -Force | Out-Null }
$LockFilePath = Join-Path $LocksDir "$PID.lock"
@{
    pid          = $PID
    script       = "run_analysis_pipeline.ps1"
    worker_index = $WorkerIndex
    worker_count = $WorkerCount
    started_at   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
} | ConvertTo-Json | Set-Content -LiteralPath $LockFilePath -Encoding UTF8

# Cross-process lock guarding Save-Manifest's read-modify-write of the
# shared manifest.json. Without this, two worker processes finishing files
# around the same moment can race: process B reads the on-disk manifest
# before process A's write lands, then B writes its own (older) snapshot
# back, silently reverting A's already-persisted update (e.g. a state_file
# field that A had just repointed at states/blocked/ or states/done/ after
# moving the physical record there) even though B never touched that entry.
# Confirmed in practice: several manifest entries pointed at a state_file
# path that no longer existed because the physical file had already been
# relocated -- the move happened, but the manifest write recording it was
# clobbered by a concurrently-running worker's own save. Scoped per-user
# (no "Global\" prefix) since all workers run in the same interactive
# session.
$script:ManifestMutex = New-Object System.Threading.Mutex($false, "AnalysisPipelineManifestLock")

# The stage roster (order, prompts-by-reference, input composition) lives in
# one shared file so this script and generate_analysis_queue.ps1 can't drift
# out of sync with each other - see pipeline_stages.ps1 for the full chain.
# file_queue_orchestrator_agent (this script itself, not an LLM stage) is the
# only entry Get-AllAgentNames returns that $StageAgents excludes.
. (Join-Path $PSScriptRoot "pipeline_stages.ps1")
$StageAgents = Get-AllAgentNames | Select-Object -Skip 1

# The manifest read-repair helpers both live in one shared file for the same
# reason the roster does: this script, queue_eta.ps1 and backfill_new_stage.ps1
# all read manifest.json and must repair the exact same corruption patterns the
# exact same way. See manifest_repair.ps1 for what each tier covers and for the
# real-incident evidence behind its search bounds.
. (Join-Path $PSScriptRoot "manifest_repair.ps1")

# Tag every printed line with which worker wrote it. This is done at the
# source (not left to the parallel orchestrator's job-output prefixing)
# because when two workers' raw console output interleaves -- whether via
# Start-Job streaming or two terminals sharing one window -- lines from
# different workers can otherwise land next to each other with no way to
# tell them apart.
$WorkerTag = if ($WorkerCount -gt 1) { "[Worker $($WorkerIndex + 1)] " } else { "" }

# One consistent color per worker (cycling if there are ever more workers
# than colors), so interleaved output from multiple workers is visually
# separable at a glance instead of just by reading the [Worker N] text.
# Red stays reserved for genuine errors/BLOCKED lines regardless of which
# worker printed them -- that signal is more useful staying consistent than
# blending into a per-worker color.
$WorkerColorPalette = @("Cyan", "Yellow", "Magenta", "Green", "Blue", "DarkCyan", "DarkYellow", "DarkMagenta")
$WorkerLogColor = if ($WorkerCount -gt 1) { $WorkerColorPalette[$WorkerIndex % $WorkerColorPalette.Count] } else { "White" }

# Per-process (this worker's own) rolling average of completed-file seconds,
# used by Get-EstimatedFileSeconds for the stall guard's "par processus"
# budget -- a worker's own recent throughput is a better predictor of its
# next file than a global average across every worker/model.
$script:WorkerFileSecondsHistory = New-Object System.Collections.Generic.List[double]

function Log {
    param([string]$Text, [string]$Color = "White")
    $effectiveColor = if ($Color -eq "Red") { "Red" } else { $WorkerLogColor }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $WorkerTag$Text" -ForegroundColor $effectiveColor
}

# ---------------- System prompts, one per skill in skills/ ----------------

$SanitizerSystemPrompt = @'
You are the Sanitizer & Context Ingestion Agent for a legacy modernization pipeline (COBOL, Ingres 4GL/OSQ, report-writer, DCL, PHP, shell, embedded-SQL C). You receive raw legacy source and, optionally, a related SQL schema (DDL). Your job:
1. Strip boilerplate: copyright/license headers, generated-code banners, redundant comment blocks, pure noise.
2. Preserve all functionally meaningful code, comments explaining business intent, and every SQL/database statement verbatim.
3. Identify every table/column reference and, if schema context is provided, append a brief inline note of that table's relevant columns and types.
4. Do not invent schema definitions that were not provided.
Output ONLY the resulting "Sanitised Code Context" as plain text: cleaned code annotated with schema notes. No preamble, no markdown fences, no summary.
'@

# These stay as top-level variables (one per stage, for readability) rather
# than moving into pipeline_stages.ps1's data table; each middle stage's
# entry there references its prompt by variable name (SystemPromptVar) and
# looks it up via Get-Variable at call time, so static analysis can't see the
# use and will flag these as "assigned but never used" - a false positive.
$BusinessDomainSystemPrompt = @'
You are the Business Domain Extractor Agent. You receive a Sanitised Code Context. Your job:
1. Identify the business area and core entities this module operates on.
2. Map database tables and program sections to business objects, workflows, and lifecycle states.
3. Summarize the operational rules, calculations, and validations that encode business policy, in plain language.
4. Label anything not explicit in the code as a hypothesis rather than confirmed behavior.
Output ONLY plain text under these labeled sections: BUSINESS AREA, CORE ENTITIES, WORKFLOW STEPS, POLICY RULES, AMBIGUITIES/HYPOTHESES. No markdown fences, no extra commentary.
'@

$StructuralMapperSystemPrompt = @'
You are the Source AST & Structural Mapper Agent. You receive a Sanitised Code Context and a Business Domain summary. Your job:
1. List every entry point (paragraph, procedure, section, function, screen, or script invocation) by name.
2. Describe control-flow paths: sequence, branching (IF/GOTO/PERFORM/CALL), loops, and how entry points relate to each other.
3. List every database operation (SELECT/INSERT/UPDATE/DELETE/DDL) with table, operation, and columns involved.
4. List external dependencies: included copybooks/files, called programs, invoked scripts, network/API calls.
5. Note any dead code, repeated patterns, or coupling hotspots relevant to migration risk.
Output ONLY plain text under these labeled sections: ENTRY POINTS, CONTROL FLOW, DATABASE OPERATIONS, DEPENDENCIES, HOTSPOTS. No markdown fences, no extra commentary.
'@

$BusinessLogicSystemPrompt = @'
You are the Business Logic Extractor Agent. You receive a Sanitised Code Context, a Structural Breakdown, and a Business Domain summary. Your job:
1. Translate procedural constructs (GOTO, loops, status/return codes, conditionals) into step-by-step business rules.
2. Document every calculation, formula, and data validation rule in plain language, preserving the exact meaning of status codes and flags.
3. Identify dead code: branches, conditions, or procedures that appear unreachable or unused.
4. Note edge cases, retries, default values, and exception-handling behavior.
Output ONLY plain text under these labeled sections: BUSINESS RULES, VALIDATIONS, CALCULATIONS, DEAD CODE, EDGE CASES. No markdown fences, no extra commentary.
'@

$SecuritySystemPrompt = @'
You are the Security & Compliance Analyst. You receive a Sanitised Code Context, a Structural Breakdown, and a Business Logic summary. Your job:
1. Detect hardcoded credentials, secrets, or unsafe configuration patterns.
2. Review authentication/authorization logic for missing or weak controls.
3. Analyze how PII or sensitive data is stored, logged, or propagated.
4. Identify SQL/command/file/API injection risk and unsafe shell usage.
5. Check for audit logging on sensitive or regulated operations, and flag relevant compliance implications.
Base every finding on code evidence; separate confirmed vulnerabilities from likely risks.
Output ONLY plain text under these labeled sections: AUTHN/AUTHZ, SECRETS, PII HANDLING, INJECTION RISK, AUDIT LOGGING, COMPLIANCE NOTES. No markdown fences, no extra commentary.
'@

$PerformanceSystemPrompt = @'
You are the Performance & Scalability Analyst. You receive a Structural Breakdown and a Business Logic summary. Your job:
1. Identify expensive loops, nested processing, repeated database access, and blocking calls.
2. Assess CPU/memory/I-O pressure and batch-processing bottlenecks.
3. Estimate how the module behaves under growing transaction volume.
4. Tie performance risks to concrete code patterns, not speculation.
Output ONLY plain text under these labeled sections: HOTSPOTS, RESOURCE PATTERNS, SCALING CONSTRAINTS, MODERNIZATION IMPLICATIONS. No markdown fences, no extra commentary.
'@

$TestValidationSystemPrompt = @'
You are the Test & Validation Analyst. You receive a Structural Breakdown and a Business Logic summary. Your job:
1. Assess whether unit, integration, or regression tests appear to exist or are referenced for this module.
2. Determine whether critical paths have any explicit validation evidence.
3. Identify missing or weak verification around edge cases and failure paths.
4. Catalog known issues, assumptions, and manual validation steps that would be needed before migration.
Be explicit about confidence levels and missing proof; do not assume tests exist without evidence.
Output ONLY plain text under these labeled sections: TEST COVERAGE, VALIDATION EVIDENCE, GAPS, KNOWN ISSUES, MIGRATION VERIFICATION NEEDED. No markdown fences, no extra commentary.
'@

$DiagramSystemPrompt = @'
You are the Diagram Designer & Context Visualizer. You receive the Business Domain, Structural, Business Logic, Security, Performance, and Test Validation findings for one module. Your job:
1. Produce a single Mermaid flowchart (flowchart TD) showing entry points, key procedures, data access, and dependencies.
2. Mark decision branches, validation rules, and exceptional paths.
3. Annotate critical technical-debt, security, or dependency hotspots directly on relevant nodes/edges as short labels.
Keep it readable: summarize, do not enumerate every line of code.
Output ONLY a single fenced Mermaid code block (```mermaid ... ```) and nothing else.
'@

$NarrativeWriterSystemPrompt = @'
You are the Narrative Writer Agent for a legacy modernization pipeline. You receive the Business Domain, Structural, Business Logic, Security, Performance, and Test Validation findings for one module. Your job is to explain this module's PURPOSE - why it exists and what business role it fills - as prose a developer or business stakeholder can read on its own, without needing the rest of the report.
1. Lead with what business need this module serves and why it exists.
2. Explain what it actually does to serve that need, grounded in its real entry points and business rules (from the Structural and Business Logic findings) - not generic or invented business narrative.
3. Briefly note how it relates to what it depends on or is depended on by, if relevant.
4. Do NOT restate the Security, Performance, or Test Validation findings, and do not re-catalog the Structural breakdown - those already have their own report sections. Use them only as grounding for the purpose explanation.
Output ONLY the Markdown narrative as plain prose and headings. No JSON, no fenced code block, no preamble or commentary outside the document itself.
'@

# The one stage whose output is parsed as JSON. Array-of-object fields from
# the full report schema are deliberately flattened to strings here (see
# header comment) to avoid grammar-constrained decoding entirely -- this
# call uses no response_format, just a plain-text JSON instruction, parsed
# and validated by this script afterward.
$ArchitectureSpecSystemPrompt = @'
You are the Architecture & Spec Writer Agent, the final synthesis step of a legacy modernization pipeline. You receive: the file path, and the prior findings from the Business Domain, Structural, Business Logic, Security, Performance, and Test Validation agents for one legacy source module. Compile them into a single JSON object with EXACTLY this shape (all fields required; use empty string/array/false if genuinely unknown, never omit a key).

The shape below is a FORMAT TEMPLATE, not example content. Every angle-bracketed token like <string> or <short title> describes what kind of value belongs there -- it is never a literal value to copy into your output. Every array or object you emit must be built from the real findings given to you below. If a section genuinely has zero real findings, emit an empty array [], never an invented or template-derived entry. Every field whose template shows options separated by "|" is an enum: your value must be exactly one of those listed options, never a value outside that list -- for example, database_interactions.operation_type must be one of READ, WRITE, UPDATE, DELETE, SCHEMA_DDL, or STORED_PROCEDURE_EXEC, never a raw SQL verb like SELECT. Every closing bracket must match its own opening bracket's type ( { with }, [ with ] ) -- after finishing a nested array or object field, the very next closing bracket you write still belongs to whatever container you were in before that nested field, not to the nested field you just closed.

{
  "module_metadata": {"file_path": "", "programming_language": "", "language_version": "", "module_scope": "file|class|package|procedure|module|script", "primary_purpose": ""},
  "source_evidence": {"symbol_name": "<function, procedure, class, or routine name analyzed>", "source_line_start": 0, "source_line_end": 0, "analysis_basis": "direct_code|inferred_from_patterns|schema_cross_reference|manual_assumption", "confidence_level": 0.0, "evidence_summary": "<short narrative of the code evidence supporting this analysis>"},
  "execution_context": {"entrypoint_type": "batch_job|api_endpoint|screen_transaction|scheduled_process|cli_command|report_generator|message_handler", "trigger_or_invocation": "<how this routine starts or is called in production>", "runtime_environment": "<OS, runtime, server, or platform context>", "config_files_used": ["<config/parameter file or manifest influencing behavior>"], "environment_variables_used": ["<env var or runtime flag consumed>"]},
  "interface_contracts": {"input_schema": ["<input parameter, record field, or payload element accepted>"], "output_schema": ["<output value, generated record, or response field produced>"], "data_formats": ["<e.g. JSON, CSV, flat file, fixed-width, XML, DB records>"], "parameter_validation_rules": ["<rule used to reject or normalize an input value>"], "default_and_null_handling": "<description of null/default behavior>"},
  "architectural_layer": {"primary_layer": "interaction|business_logic|data_access|configuration|infrastructure|cross_cutting", "layer_confidence_score": 0.0, "entry_points": [""], "state_management_pattern": "stateless|stateful_in_memory|database_backed|session_bound|global_mutable_state"},
  "quality_metrics": {"cyclomatic_complexity": 0, "maintainability_index": 0.0, "lines_of_code": 0, "comment_density_ratio": 0.0, "halstead_volume": 0.0, "composite_quality_score": 0.0},
  "functional_requirements": [{"requirement_id": "<string, e.g. REQ-BL-001>", "title": "<short descriptive title>", "description": "<the business logic, formula, or conditional rule this requirement captures>", "business_rule_type": "computation|validation|data_transformation|workflow_routing|authorization|audit_logging", "source_line_range": "<start-end line numbers, e.g. 102-145>", "input_parameters": ["<data structure, argument, or env var this logic consumes>"], "output_artifacts": ["<return value, modified state, or external message this logic produces>"]}],
  "technical_debt_and_code_smells": [{"issue_id": "<string, e.g. DEBT-SEC-004>", "category": "deprecated_api|security_vulnerability|hardcoded_credentials|god_class_or_method|dead_code|tight_coupling|missing_error_handling|manual_deployment_dependency", "severity": "critical|high|medium|low|informational", "source_location": "<symbol name or line range>", "description": "<why this is technical debt>", "remediation_strategy": "<recommended refactoring technique>"}],
  "dependencies_and_integrations": {"internal_module_dependencies": [""], "external_library_dependencies": [{"library_name": "<string>", "version_constraint": "<string>", "is_deprecated": false, "end_of_life_status": "<string>"}], "database_interactions": [{"operation_type": "READ|WRITE|UPDATE|DELETE|SCHEMA_DDL|STORED_PROCEDURE_EXEC", "target_entity": "<table or entity name>", "execution_mechanism": "<e.g. embedded SQL, ORM call, stored procedure>"}], "network_and_api_calls": [""], "integration_ceiling_risk": false},
  "security_findings": {"authn_authz_checks": "", "secret_or_credential_usage": "", "pii_handling": "", "injection_risk": "", "audit_logging_behavior": ""},
  "data_lineage": {"tables_and_entities": [""], "join_and_relationship_usage": "", "transaction_boundaries": "", "file_or_message_io": "", "data_classification": ""},
  "exception_handling": {"exception_types_handled": [""], "retry_policy": "", "timeout_behavior": "", "rollback_behavior": "", "logging_and_alerting": ""},
  "test_status": {"unit_test_coverage": "", "integration_test_coverage": "", "regression_test_status": "", "manual_validation_steps": [""], "known_issues": [""]},
  "business_impact": {"business_process_owner": "", "criticality_level": "low|medium|high|critical", "sla_or_availability_tolerance": "", "regulatory_constraints": [""], "operational_risk": ""},
  "iso_25010_attributes": {
    "functional_suitability": {"score": 0.0, "findings": ""}, "performance_efficiency": {"score": 0.0, "findings": ""},
    "compatibility": {"score": 0.0, "findings": ""}, "usability": {"score": 0.0, "findings": ""},
    "reliability": {"score": 0.0, "findings": ""}, "security": {"score": 0.0, "findings": ""},
    "maintainability": {"score": 0.0, "findings": ""}, "portability": {"score": 0.0, "findings": ""}
  },
  "modernization_recommendations": {"recommended_7r_strategy": "Rehost|Replatform|Refactor|Rearchitect|Rebuild|Retire|Retain", "target_architecture_pattern": "microservice|event_driven_module|serverless_function|modular_monolith_component|batch_job", "refactoring_complexity_level": "trivial|moderate|complex|extreme_risk", "estimated_person_hours": 0, "strangler_fig_suitability": false, "target_technology_stack": [""], "step_by_step_migration_plan": [""]}
}

Return ONLY the JSON object, no prose outside it, no markdown fences. Never copy this template's angle-bracketed placeholder tokens verbatim into your output -- every value must come from the real findings above. If a string value itself contains a double-quote character -- a quoted variable name, file path, or source snippet you are echoing -- escape it as \" ; never leave a bare " inside a string value.
'@

# ---------------- Ollama plumbing ----------------

function Test-OllamaServerUp {
    param([string]$BaseUrl)
    try {
        $base = $BaseUrl -replace '/v1/?$', ''
        Invoke-RestMethod -Method Get -Uri "$base/api/tags" -TimeoutSec 5 | Out-Null
        return $true
    }
    catch { return $false }
}

# Distinguishes "Ollama itself stopped answering" (its server process
# crashed, or the model runner reset the connection mid-request) from an
# ordinary application-level failure (bad JSON, our own stall-budget
# timeout, etc.). The stall guard's $isStall check doesn't catch this case --
# a crashed connection typically fails in milliseconds, nowhere near this
# call's own timeout/budget -- so it needs its own detection to trigger the
# wait-and-restart recovery instead of blocking the file after one failure.
function Test-IsTransientOllamaError {
    param([string]$Message)
    if (-not $Message) { return $false }
    return $Message -match 'forcibly closed|wsarecv|Unable to connect to the remote server|actively refused|connection was closed|Ollama HTTP 5\d\d|error was encountered while running the model|underlying connection was closed|No connection could be made'
}

# With $ErrorActionPreference = "Stop" (set at script scope), a native exe's
# stderr output -- even ollama's own benign status/success text -- becomes a
# terminating PowerShell error the moment PowerShell turns it into a
# NativeCommandError, REGARDLESS of where the stream is redirected (*> $null
# does not prevent this in Windows PowerShell 5.1 -- confirmed by hitting
# this exact crash, first with the lms CLI and again with ollama). What
# actually matters is $ErrorActionPreference at the time the native command
# runs, so this locally overrides it to "SilentlyContinue" for the call and
# restores it afterward; success/failure is read from $LASTEXITCODE, not
# the streams.
function Invoke-OllamaCommand {
    param([string[]]$ArgList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        & ollama @ArgList *> $null
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    return $LASTEXITCODE
}

# Ensures a dedicated Ollama instance is up at -OllamaUrl, starting one if
# needed, then pre-warms -Model so its cold-load latency happens here
# instead of eating into the stall guard's budget for the first real file.
# CudaVisibleDevices empty = don't manage GPU pinning at all (assume
# whatever's already listening on this port, for manual/standalone use).
function Start-OllamaInstanceIfNeeded {
    param([string]$BaseUrl, [string]$CudaDevice, [string]$ModelsPath, [string]$ModelKey, [int]$TimeoutSeconds = 60)
    if (-not (Test-OllamaServerUp -BaseUrl $BaseUrl)) {
        $bareHost = $BaseUrl -replace '^https?://', '' -replace '/v1/?$', ''
        Log "Ollama instance not reachable at $BaseUrl -- starting one (CUDA_VISIBLE_DEVICES=$CudaDevice) ..." "Yellow"
        $prevCuda = $env:CUDA_VISIBLE_DEVICES
        $prevHost = $env:OLLAMA_HOST
        $prevModels = $env:OLLAMA_MODELS
        try {
            if ($CudaDevice) { $env:CUDA_VISIBLE_DEVICES = $CudaDevice }
            $env:OLLAMA_HOST = $bareHost
            if ($ModelsPath) { $env:OLLAMA_MODELS = $ModelsPath }
            Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden | Out-Null
        }
        finally {
            # Env vars are only used to seed the new process at launch --
            # clear them from this session right away so they don't leak
            # into anything else this worker does afterward (proven pattern
            # from live testing: Start-Process children inherit the parent's
            # env at spawn time, so this is safe to clear immediately after).
            if ($null -eq $prevCuda) { Remove-Item Env:\CUDA_VISIBLE_DEVICES -ErrorAction SilentlyContinue } else { $env:CUDA_VISIBLE_DEVICES = $prevCuda }
            if ($null -eq $prevHost) { Remove-Item Env:\OLLAMA_HOST -ErrorAction SilentlyContinue } else { $env:OLLAMA_HOST = $prevHost }
            if ($null -eq $prevModels) { Remove-Item Env:\OLLAMA_MODELS -ErrorAction SilentlyContinue } else { $env:OLLAMA_MODELS = $prevModels }
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-OllamaServerUp -BaseUrl $BaseUrl) { break }
            Start-Sleep -Seconds 2
        }
        if (-not (Test-OllamaServerUp -BaseUrl $BaseUrl)) {
            throw "Ollama instance did not come up at $BaseUrl after starting it."
        }
    }
    Log "Pre-warming '$ModelKey' on $BaseUrl ..." "Yellow"
    $bareBase = $BaseUrl -replace '/v1/?$', ''
    try {
        Invoke-RestMethod -Method Post -Uri "$bareBase/api/generate" -TimeoutSec 300 -ContentType "application/json" `
            -Body (@{ model = $ModelKey; prompt = "hi"; stream = $false } | ConvertTo-Json) | Out-Null
    }
    catch {
        Log "  pre-warm request failed (continuing anyway, first real stage call will retry the load): $($_.Exception.Message)" "Red"
    }
}

function Invoke-OllamaChat {
    param(
        [Parameter(Mandatory = $true)][string]$SystemPrompt,
        [Parameter(Mandatory = $true)][string]$UserContent,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ModelName,
        [double]$Temp = 0.2,
        [int]$MaxTokens = 0,
        [int]$Timeout = 300,
        # Printed via Log (so it already gets the [Worker N] prefix) every
        # HeartbeatSeconds while this call is in flight, so a long-running
        # stage doesn't look indistinguishable from a hung one. Empty string
        # disables heartbeats.
        [string]$HeartbeatLabel = "",
        [int]$HeartbeatSeconds = 5
    )
    $body = @{
        model       = $ModelName
        messages    = @(
            @{ role = "system"; content = $SystemPrompt }
            @{ role = "user"; content = $UserContent }
        )
        temperature = $Temp
        stream      = $false
    }
    if ($MaxTokens -gt 0) { $body.max_tokens = $MaxTokens }
    $json = $body | ConvertTo-Json -Depth 10

    # A plain Invoke-RestMethod call blocks this thread for the whole
    # duration with no way to print in between. Using HttpClient directly
    # lets the call run async while this thread polls Task.Wait() on a
    # short interval and prints a heartbeat each time it's not done yet --
    # the timeout behavior (abort after $Timeout seconds) is preserved via
    # the CancellationTokenSource instead of -TimeoutSec.
    $client = [System.Net.Http.HttpClient]::new()
    $cts = [System.Threading.CancellationTokenSource]::new()
    try {
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
        $cts.CancelAfter([TimeSpan]::FromSeconds($Timeout))
        $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
        $task = $client.PostAsync("$BaseUrl/chat/completions", $content, $cts.Token)

        $elapsed = 0
        try {
            while (-not $task.Wait($HeartbeatSeconds * 1000)) {
                $elapsed += $HeartbeatSeconds
                if ($HeartbeatLabel) { Log "$HeartbeatLabel ... still working (${elapsed}s)" "DarkGray" }
            }
        }
        catch {
            # Task.Wait() doesn't just return $false on timeout the way a
            # plain polling loop would -- once the task itself transitions to
            # Canceled/Faulted (e.g. our own CancelAfter() firing while Wait()
            # is blocked), Wait() throws immediately instead. The task's own
            # IsFaulted/IsCanceled below still correctly reflect why, so just
            # fall through to those instead of letting this exception surface
            # as an opaque "One or more errors occurred." (confirmed via a
            # local test: this is exactly what happened without this catch).
        }

        if ($task.IsFaulted) {
            $inner = $task.Exception.InnerException
            throw ($(if ($inner) { $inner.Message } else { $task.Exception.Message }))
        }
        if ($task.IsCanceled) {
            throw "Request timed out after ${Timeout}s"
        }
        $response = $task.Result
        $bodyText = $response.Content.ReadAsStringAsync().Result
        if (-not $response.IsSuccessStatusCode) {
            throw "Ollama HTTP $([int]$response.StatusCode): $bodyText"
        }
    }
    finally {
        $cts.Dispose()
        $client.Dispose()
    }

    $parsed = $bodyText | ConvertFrom-Json
    $choice = $parsed.choices[0]
    return [PSCustomObject]@{
        Content      = $choice.message.content
        FinishReason = $choice.finish_reason
        Usage        = $parsed.usage
    }
}

# Stall recovery: unload this worker's own model on its own dedicated
# instance only (never touches other workers' instances) via `ollama stop`,
# targeted at this instance through $env:OLLAMA_HOST. No reload step is
# needed -- unlike LM Studio's lms load/unload, Ollama lazy-loads the model
# again automatically on the very next request, which is the retried stage
# call right after this returns.
function Restart-OllamaInstance {
    param([string]$BaseUrl, [string]$ModelKey)
    if (-not (Test-OllamaServerUp -BaseUrl $BaseUrl)) {
        # The server process itself is gone (crashed), not just the model
        # runner -- `ollama stop` has no process to talk to. Relaunch the
        # whole instance the same way Start-OllamaInstanceIfNeeded does at
        # startup, using this same worker's own CUDA device / models path.
        Log "    [recovery] Ollama server at $BaseUrl is unreachable -- relaunching the instance" "Yellow"
        Start-OllamaInstanceIfNeeded -BaseUrl $BaseUrl -CudaDevice $CudaVisibleDevices -ModelsPath $OllamaModelsPath -ModelKey $ModelKey | Out-Null
        return $true
    }
    $bareHost = $BaseUrl -replace '^https?://', '' -replace '/v1/?$', ''
    Log "    [recovery] stopping '$ModelKey' on $BaseUrl ..." "Yellow"
    $prevHost = $env:OLLAMA_HOST
    try {
        $env:OLLAMA_HOST = $bareHost
        $exitCode = Invoke-OllamaCommand -ArgList @("stop", $ModelKey)
        if ($exitCode -ne 0) { Log "    [recovery] 'ollama stop' exited with code $exitCode (continuing anyway)" "Red" }
    }
    finally {
        if ($null -eq $prevHost) { Remove-Item Env:\OLLAMA_HOST -ErrorAction SilentlyContinue } else { $env:OLLAMA_HOST = $prevHost }
    }
    Log "    [recovery] stopped -- it will lazy-load again on the retried request." "Yellow"
    return $true
}

# ---------------- State / manifest helpers ----------------

function Get-UtcNowStamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$script:Cp1252Encoding = [System.Text.Encoding]::GetEncoding(1252)

# Reads legacy source/SQL text as Windows-1252 -- these files predate UTF-8 and
# carry raw accented bytes (this codebase's source trees are ~80% non-ASCII by
# file count). Get-Content's own "-Encoding Default" used to cover this, but
# "Default" means the OS ANSI codepage under Windows PowerShell (cp1252 here)
# and means UTF-8 under PowerShell 7/.NET Core -- same flag, silently different
# decoding, which would corrupt every accented character the moment this script
# runs under pwsh instead of powershell.exe. Decoding explicitly via
# GetEncoding(1252) keeps the result identical on both engines.
function Read-LegacySourceText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return $script:Cp1252Encoding.GetString($bytes)
}

# Write-Utf8NoBom (the atomic, verified manifest write) comes from
# pipeline_common.ps1, dot-sourced near the top of this script -- this script,
# backfill_new_stage.ps1 and generate_analysis_queue.ps1 all write manifest.json
# and used to carry their own copy of it.

# Repair-StrayNonAsciiCharacters (tier 1) and Repair-SingleBitFlipCharacter
# (tier 2) live in manifest_repair.ps1, dot-sourced near the top of this script.
function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "No manifest found at $ManifestPath. Run generate_analysis_queue.ps1 first."
    }
    # Retry on a locked-file IOException (AV/indexer, same as Write-Utf8NoBom)
    # or a JSON parse failure: manifest.json is tens of MB and rewritten by
    # two workers throughout the run, so a read landing in the split-second
    # around another process's atomic File.Replace can occasionally catch a
    # torn/incomplete file even though the replace itself is atomic. Either
    # failure clears within milliseconds once the other write finishes.
    $maxAttempts = 5
    # Tier 2 is the expensive one (a bounded search of full-document reparses),
    # so it is attempted at most once per Read-Manifest call: repeating it on
    # every retry would multiply its bounded cost by the retry count, and the
    # only other reason a parse can fail here (a torn read around another
    # process's atomic replace) is transient -- the untouched tier-1 scan still
    # runs on every attempt.
    $bitFlipSearchUsed = $false
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $raw = $null
        try {
            $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
            return ($raw | ConvertFrom-Json)
        }
        catch [System.IO.IOException] {
            if ($attempt -eq $maxAttempts) { throw }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
        catch {
            # Parsed content, but ConvertFrom-Json failed -- try the known
            # repairs before falling back to a normal retry. Both only fix the
            # in-memory copy for this read; the next successful Save-Manifest
            # call naturally heals the on-disk copy too, since it re-reads (via
            # this same function) before writing.
            $parseErrorMessage = $_.Exception.Message
            if ($raw) {
                $repaired = Repair-StrayNonAsciiCharacters -Text $raw
                if ($repaired) {
                    try {
                        $result = $repaired | ConvertFrom-Json
                        Log "  [Read-Manifest] Auto-repaired a stray non-ASCII character in manifest.json and re-parsed successfully." "Yellow"
                        return $result
                    }
                    catch { }
                }
                if (-not $bitFlipSearchUsed) {
                    $bitFlipSearchUsed = $true
                    $bitFlip = Repair-SingleBitFlipCharacter -Text $raw -ParseErrorMessage $parseErrorMessage
                    if ($bitFlip) {
                        try {
                            $result = $bitFlip.Text | ConvertFrom-Json
                            # Log the forensics, not just the fact: position,
                            # both characters, which bit, how far it was from
                            # where the parser noticed, and how many candidates
                            # it took are the only evidence this project ever
                            # gets about the hardware fault behind these
                            # incidents.
                            Log ("  [Read-Manifest] Auto-repaired a single-bit-flip substitution in manifest.json at offset {0} ('{1}' 0x{2:X4} -> '{3}' 0x{4:X4}, bit {5}, {6} chars from the reported location, after {7} candidate reparses) and re-parsed successfully." -f $bitFlip.Position, $bitFlip.OriginalChar, $bitFlip.OriginalCodePoint, $bitFlip.CorrectedChar, $bitFlip.CorrectedCodePoint, $bitFlip.BitIndex, $bitFlip.Distance, $bitFlip.Attempts) "Yellow"
                            return $result
                        }
                        catch { }
                    }
                }
            }
            if ($attempt -eq $maxAttempts) { throw }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

# Estimated seconds for one file, used as the stall guard's baseline
# (the guard's actual budget is StallMultiplier times this). Prefers this
# worker's own completed-file average from earlier in the current run (most
# representative of "par processus" throughput); falls back to the
# queue-wide average across all workers (same source queue_eta.ps1 uses)
# once any files anywhere are completed; falls back to BootstrapFileSeconds
# before any data exists at all.
function Get-EstimatedFileSeconds {
    if ($script:WorkerFileSecondsHistory.Count -gt 0) {
        return ($script:WorkerFileSecondsHistory | Measure-Object -Average).Average
    }
    if (Test-Path -LiteralPath $ManifestPath) {
        $m = Read-Manifest
        $completed = @($m.files | Where-Object { $_.status -eq "completed" -and $_.token_usage.run_total_elapsed_seconds -gt 0 })
        if ($completed.Count -gt 0) {
            return ($completed | ForEach-Object { [double]$_.token_usage.run_total_elapsed_seconds } | Measure-Object -Average).Average
        }
    }
    return $BootstrapFileSeconds
}

function Save-Manifest {
    param($Manifest, [string]$UpdatedPath)
    # With multiple worker processes sharing one manifest.json, a blind
    # overwrite from this process's in-memory copy would clobber whatever the
    # other worker(s) have written for the files they own since this copy was
    # loaded. Re-read the current on-disk manifest and splice in only the one
    # entry this call is reporting on, so concurrent workers never lose each
    # other's progress. That read-then-write pair must itself be atomic
    # across processes -- $script:ManifestMutex (acquired below) serializes
    # it against every other worker's Save-Manifest call, closing the race
    # where two workers' read-modify-write cycles interleave and the later
    # write (based on a snapshot taken before the earlier write landed)
    # silently reverts it.
    $acquired = $false
    try {
        try {
            $acquired = $script:ManifestMutex.WaitOne(60000)
        }
        catch [System.Threading.AbandonedMutexException] {
            # A previous holder exited without releasing (e.g. killed
            # mid-write) -- .NET still grants this thread ownership when it
            # throws this, so treat it as a normal acquisition rather than
            # failing the save.
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for the cross-process manifest lock."
        }

        $target = $Manifest
        if ($UpdatedPath -and (Test-Path -LiteralPath $ManifestPath)) {
            $current = Read-Manifest
            $src = $Manifest.files | Where-Object { $_.path -eq $UpdatedPath } | Select-Object -First 1
            if ($src) {
                for ($i = 0; $i -lt $current.files.Count; $i++) {
                    if ($current.files[$i].path -eq $UpdatedPath) { $current.files[$i] = $src; break }
                }
            }
            $target = $current
        }
        $json = $target | ConvertTo-Json -Depth 15
        Write-Utf8NoBom -Path $ManifestPath -Content ($json + "`n")
    }
    finally {
        if ($acquired) { $script:ManifestMutex.ReleaseMutex() }
    }
}

# Atomically claims the next available file from the shared manifest instead
# of each worker being handed a fixed slice up front -- so a worker that
# finishes faster than its peers (smaller files, a faster GPU, or just
# finishing earlier) immediately pulls more work rather than exiting while
# others are still busy. "Available" means queued/blocked, or an in_progress
# entry that's gone stale (its last_updated is older than $StaleSeconds) --
# that second case is what lets ANY worker resume a file abandoned by a
# process that crashed outright (e.g. the clr.dll access violation case
# where nothing in-script gets a chance to mark it blocked) without needing
# to be that same, now-dead worker.
# $script:ManifestMutex is a real Win32 mutex with thread-affinity recursion,
# so nesting Save-Manifest's own WaitOne inside this function's already-held
# lock (same thread, no separate runspaces here) succeeds immediately rather
# than deadlocking -- this whole find-mark-persist sequence needs to be one
# atomic critical section, otherwise two workers could both see the same
# "queued" entry as claimable in the gap between reading and writing it.
function Request-NextFile {
    param([int]$StaleSeconds = 300)
    $acquired = $false
    try {
        try {
            $acquired = $script:ManifestMutex.WaitOne(60000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Timed out waiting for the cross-process manifest lock while claiming a file."
        }

        $manifest = Read-Manifest
        $claimed = $manifest.files | Where-Object { $_.status -in @("queued", "blocked") } | Select-Object -First 1
        if (-not $claimed) {
            $nowUtc = (Get-Date).ToUniversalTime()
            $claimed = $manifest.files | Where-Object {
                if ($_.status -ne "in_progress") { return $false }
                # -is [datetime] check first, not just [datetime]::Parse($_.last_updated)
                # directly: PowerShell 7's ConvertFrom-Json auto-converts an
                # ISO-8601 "...Z" string into an actual [datetime] with
                # Kind=Utc, unlike Windows PowerShell 5.1, which leaves it as a
                # plain string. Parse() only accepts a string, so handing it an
                # already-[datetime] value forces an implicit ToString() (using
                # the default, timezone-less format) then a re-Parse() of that
                # -- which silently loses the UTC-ness, comes back
                # Kind=Unspecified, and ToUniversalTime() then treats it as
                # LOCAL time, shifting it by the machine's UTC offset (here,
                # 4 hours) and making a genuinely stale file look like it's
                # still fresh (or even in the future) -- confirmed as the
                # actual cause of a real run silently never reclaiming two
                # long-stale in_progress files after this pipeline started
                # running under PS7.
                $lastUpdated = $null
                if ($_.last_updated -is [datetime]) {
                    $lastUpdated = $_.last_updated.ToUniversalTime()
                }
                elseif ($_.last_updated) {
                    try { $lastUpdated = [datetime]::Parse($_.last_updated).ToUniversalTime() } catch {}
                }
                return (-not $lastUpdated) -or (($nowUtc - $lastUpdated).TotalSeconds -ge $StaleSeconds)
            } | Select-Object -First 1
        }
        if (-not $claimed) { return $null }

        $claimed.status = "in_progress"
        $claimed.last_updated = Get-UtcNowStamp
        Save-Manifest -Manifest $manifest -UpdatedPath $claimed.path
        return [PSCustomObject]@{ Manifest = $manifest; Entry = $claimed }
    }
    finally {
        if ($acquired) { $script:ManifestMutex.ReleaseMutex() }
    }
}

function Get-StatePath {
    param([string]$StateFileRelative)
    return Join-Path $Root ($StateFileRelative -replace '/', '\')
}

function Read-State {
    param([string]$StateFileRelative)
    $path = Get-StatePath $StateFileRelative
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-State {
    param([string]$StateFileRelative, $State)
    $path = Get-StatePath $StateFileRelative
    $json = $State | ConvertTo-Json -Depth 12
    Write-Utf8NoBom -Path $path -Content ($json + "`n")
}

# Relocates a file's state record out of states/ into a status-specific
# subfolder (done/ or blocked/), so the working states/ folder only shows
# files still in flight. Updates $Entry.state_file in place (same object as
# in $Manifest.files) so the manifest persists the new location. No-ops if
# the record already lives in the destination folder (e.g. a blocked file
# that fails again on retry).
function Move-StateFileToFolder {
    param($Entry, [string]$StateFileRelative, [string]$DestDir, [string]$DestFolderName)
    $sourcePath = Get-StatePath $StateFileRelative
    if ((Split-Path -Parent $sourcePath) -ieq $DestDir) { return $StateFileRelative }
    if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    $leaf = Split-Path -Leaf $StateFileRelative
    $destPath = Join-Path $DestDir $leaf
    Move-Item -LiteralPath $sourcePath -Destination $destPath -Force
    $newRelative = ".analysis-state/states/$DestFolderName/$leaf"
    $Entry.state_file = $newRelative
    return $newRelative
}

function Move-CompletedStateFile {
    param($Entry, [string]$StateFileRelative)
    return Move-StateFileToFolder -Entry $Entry -StateFileRelative $StateFileRelative -DestDir $StatesDoneDir -DestFolderName "done"
}

function Move-BlockedStateFile {
    param($Entry, [string]$StateFileRelative)
    return Move-StateFileToFolder -Entry $Entry -StateFileRelative $StateFileRelative -DestDir $StatesBlockedDir -DestFolderName "blocked"
}

function Remove-CodeFence {
    # Local models frequently wrap output in ```json / ```mermaid fences even
    # when told not to, and often preface it with prose ("Here is the JSON
    # object with the compiled findings:") that the old ^-anchored regex
    # didn't tolerate -- that preface made the whole match fail, so the raw
    # "Here is the JSON..." text fell through untouched and ConvertFrom-Json
    # choked on "Here" as an invalid primitive (confirmed as the dominant
    # architecture_spec_writer blocker across the queue). Matching the fence
    # anywhere in the text -- not just at the very start/end -- strips that
    # preface along with the fence.
    param([string]$Text)
    if (-not $Text) { return $Text }
    $trimmed = $Text.Trim()
    if ($trimmed -match '(?s)```[a-zA-Z0-9]*\s*\r?\n(.*?)\r?\n?```') {
        return $Matches[1].Trim()
    }
    # No fence at all -- some models emit the same prose preface around bare
    # JSON with no fence. Fall back to the outermost {...} span.
    $start = $trimmed.IndexOf('{')
    $end = $trimmed.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        return $trimmed.Substring($start, $end - $start + 1)
    }
    return $trimmed
}

function Repair-JsonEscapes {
    # architecture_spec_writer is asked to quote raw source snippets (e.g. into
    # "entry_points") for shell scripts that are themselves sed/regex one-liners
    # full of backslashes ('s/\+\s\1/g', 's#\.#,#g'). The 8B model echoes those
    # verbatim without doubling the backslash, so ConvertFrom-Json rejects the
    # result with "Unrecognized escape sequence" and the file gets stuck in
    # blocked/retry_from_architecture_spec_writer forever, since a retry only
    # re-runs this same stage against the same input and gets the same output.
    # Double any backslash that isn't already the start of a valid JSON escape
    # (\" \\ \/ \b \f \n \r \t \uXXXX) so the text becomes parseable. This is a
    # no-op on already-valid JSON, so it's safe to apply unconditionally.
    param([string]$Text)
    if (-not $Text) { return $Text }
    # Matched as alternation so a valid escape (incl. \uXXXX) is consumed as a
    # whole pair and left untouched -- a lookahead-only approach re-examines
    # the second backslash of an already-valid "\\" independently and can
    # corrupt it (e.g. "\\ " -> "\\\ ") when the char after it isn't itself a
    # valid escape starter.
    return [regex]::Replace($Text, '\\u[0-9a-fA-F]{4}|\\["\\/bfnrt]|\\', {
        param($m)
        if ($m.Value.Length -gt 1) { $m.Value } else { '\\' }
    })
}

function Repair-UnescapedEmbeddedQuotes {
    # architecture_spec_writer is sometimes asked to echo a quoted identifier,
    # file path, or source snippet into a string value (e.g. "trigger_or_
    # invocation": "Called via "SYSTEM" USING /path"). The 8B model leaves the
    # embedded quotes unescaped, which prematurely terminates the JSON string
    # as far as any parser is concerned. Distinguishing a real closing quote
    # from an embedded one that should have been escaped is undecidable in
    # general, so this uses a narrow, confidently-correct heuristic instead: a
    # quote immediately followed (past any whitespace) by one of , } ] : is
    # treated as a real terminator -- exactly what a closing quote always
    # looks like in valid JSON -- and anything else is treated as an embedded
    # quote and escaped. That makes this a no-op on already-valid JSON (a real
    # terminator is by grammar always followed by one of those four
    # characters), same posture as Repair-JsonEscapes/Repair-JsonTruncation,
    # while still being wrong on rare pathological input (e.g. quoted prose
    # that happens to end right before a naturally-occurring comma) -- an
    # accepted trade-off for a narrow, low-volume failure mode.
    param([string]$Text)
    if (-not $Text) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $chars = $Text.ToCharArray()
    $closers = @(',', '}', ']', ':')
    for ($i = 0; $i -lt $chars.Count; $i++) {
        $ch = $chars[$i]
        if ($inString) {
            if ($escaped) {
                [void]$sb.Append($ch)
                $escaped = $false
                continue
            }
            if ($ch -eq '\') {
                [void]$sb.Append($ch)
                $escaped = $true
                continue
            }
            if ($ch -eq '"') {
                $j = $i + 1
                while ($j -lt $chars.Count -and [char]::IsWhiteSpace($chars[$j])) { $j++ }
                $nextChar = if ($j -lt $chars.Count) { [string]$chars[$j] } else { $null }
                if ($nextChar -in $closers) {
                    [void]$sb.Append('"')
                    $inString = $false
                }
                else {
                    [void]$sb.Append('\"')
                }
                continue
            }
            [void]$sb.Append($ch)
        }
        else {
            [void]$sb.Append($ch)
            if ($ch -eq '"') { $inString = $true }
        }
    }
    return $sb.ToString()
}

function Repair-MismatchedContainerClosers {
    # architecture_spec_writer occasionally closes a container with the
    # wrong bracket type -- confirmed as the dominant real failure mode
    # (48/59, 81.4%, of captured .raw.txt failures): after generating a
    # deeply-nested array-of-objects field (e.g. database_interactions
    # inside dependencies_and_integrations), the model's closing-bracket
    # habit repeats the array type instead of returning to the enclosing
    # object's own type once it's actually done with that whole container.
    # Walks the text tracking a stack of expected closers, the same
    # approach Repair-JsonTruncation already uses -- but instead of only
    # appending missing closers at EOF, this corrects a closer's type in
    # place: whatever character is actually seen, the stack's own expected
    # closer is what gets emitted. That's a no-op on already-valid JSON
    # (there, the seen character always already equals what the stack
    # expects, so emitting the expected one IS emitting it unchanged) and a
    # correction wherever it doesn't.
    param([string]$Text)
    if (-not $Text) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $stack = New-Object System.Collections.Generic.Stack[char]
    $inString = $false
    $escaped = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($inString) {
            [void]$sb.Append($ch)
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        switch ($ch) {
            '"' { $inString = $true; [void]$sb.Append($ch) }
            '{' { $stack.Push('}'); [void]$sb.Append($ch) }
            '[' { $stack.Push(']'); [void]$sb.Append($ch) }
            '}' { [void]$sb.Append($(if ($stack.Count -gt 0) { $stack.Pop() } else { $ch })) }
            ']' { [void]$sb.Append($(if ($stack.Count -gt 0) { $stack.Pop() } else { $ch })) }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

function Repair-JsonTruncation {
    # Separately from bad escaping, the 8B model sometimes drops just the final
    # closing brace(s) of the object even on a normal (non-length-capped) stop
    # -- seen on killprocesssigare.sh, where completion_tokens landed nowhere
    # near MaxTokensPerStage yet the response was one "}" short. Walk the text
    # tracking open braces/brackets, skipping over string contents (respecting
    # backslash-escaped characters so a quote inside a string doesn't look like
    # a close), and append whatever closers are still outstanding at EOF. A
    # no-op on already-well-formed JSON.
    param([string]$Text)
    if (-not $Text) { return $Text }
    $stack = New-Object System.Collections.Generic.Stack[char]
    $inString = $false
    $escaped = $false
    foreach ($ch in $Text.ToCharArray()) {
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inString = $false }
            continue
        }
        switch ($ch) {
            '"' { $inString = $true }
            '{' { $stack.Push('}') }
            '[' { $stack.Push(']') }
            '}' { if ($stack.Count -gt 0) { [void]$stack.Pop() } }
            ']' { if ($stack.Count -gt 0) { [void]$stack.Pop() } }
        }
    }
    if ($stack.Count -eq 0 -and -not $inString) { return $Text }
    $suffix = ''
    if ($inString) { $suffix += '"' }
    while ($stack.Count -gt 0) { $suffix += $stack.Pop() }
    return $Text + $suffix
}

# The top-level "source code" container folder and its per-system subfolder
# names are normalized to the canonical system name; the rest of the real
# source subfolder path is kept as-is beneath it.
$SystemNameMap = @{
    "gesacad cobol" = "GESACAD"
    "sigare 4gl"    = "SIGARE"
    "sigare web"    = "SIGARE-WEB"
}

# Some repos nest an immediate subfolder that just repeats their own
# container name (e.g. "source code/Gesacad cobol/gesacad/cobol/..." - the
# "gesacad" folder is redundant with the "Gesacad cobol" container it lives
# in). Listed here per system key so the redundant segment is dropped from
# output paths instead of showing up twice (e.g. "GESACAD/gesacad/cobol").
$RedundantContainerSubfolder = @{
    "gesacad cobol" = "gesacad"
}

# Mirrors the source's own folder structure under outputs/ (e.g.
# "source code/Gesacad cobol/gesacad/cobol/aep_4_5_3_2.scb" becomes
# "GESACAD/cobol/aep_4_5_3_2.scb") instead of flattening it into one
# long name. Only characters illegal in Windows paths are stripped from each
# segment.
function Get-SanitizedRelativeDir {
    param([string]$RelativePath)
    $segments = @($RelativePath -split '/' | ForEach-Object { $_ -replace '[:*?"<>|]', '' })
    if ($segments.Count -ge 2 -and $segments[0] -ieq "source code") {
        $systemKey = $segments[1].ToLowerInvariant()
        $systemName = if ($SystemNameMap.ContainsKey($systemKey)) { $SystemNameMap[$systemKey] } else { $segments[1] }
        $rest = @($segments[2..($segments.Count - 1)])
        if ($rest.Count -ge 2 -and $RedundantContainerSubfolder.ContainsKey($systemKey) -and $rest[0] -ieq $RedundantContainerSubfolder[$systemKey]) {
            $rest = @($rest[1..($rest.Count - 1)])
        }
        $segments = @($systemName) + $rest
    }
    return ($segments -join [System.IO.Path]::DirectorySeparatorChar)
}

# ---------------- Pipeline ----------------

function Get-SchemaContext {
    param([System.IO.FileInfo]$SourceFile)
    $siblingSql = Get-ChildItem -LiteralPath $SourceFile.DirectoryName -Filter "*.sql" -File -ErrorAction SilentlyContinue
    if (-not $siblingSql) { return $null }
    return ($siblingSql | ForEach-Object { Read-LegacySourceText -Path $_.FullName }) -join "`n`n"
}

function Set-AgentTiming {
    param($State, [string]$AgentName, [string]$ModelName, [datetime]$StartedAt, [datetime]$EndedAt, $Usage)
    $elapsed = [math]::Round(($EndedAt - $StartedAt).TotalSeconds, 2)
    if (-not $State.token_usage.agents.($AgentName)) {
        # A state file saved before this agent existed in the chain (e.g. a
        # file completed prior to narrative_writer being added) won't have
        # this property yet -- same Windows PowerShell 5.1 "property cannot
        # be found on assignment" issue Update-ManifestEntry's Add-Member
        # calls above already work around, just one level deeper.
        $State.token_usage.agents | Add-Member -NotePropertyName $AgentName -NotePropertyValue ([PSCustomObject](New-EmptyAgentUsage)) -Force
    }
    $agent = $State.token_usage.agents.($AgentName)
    $agent.model_name = $ModelName
    $agent.started_at = $StartedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $agent.ended_at = $EndedAt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $agent.elapsed_seconds = $elapsed
    if ($Usage) {
        $agent.prompt_tokens = $Usage.prompt_tokens
        $agent.completion_tokens = $Usage.completion_tokens
        $agent.total_tokens = $Usage.total_tokens
        $State.token_usage.run_total_tokens += [int]$Usage.total_tokens
    }
    $State.token_usage.run_total_elapsed_seconds = [math]::Round($State.token_usage.run_total_elapsed_seconds + $elapsed, 2)
}

function Save-Intermediate {
    param([string]$OutDir, [string]$AgentName, [string]$Content)
    $interDir = Join-Path $OutDir "intermediates"
    if (-not (Test-Path -LiteralPath $interDir)) { New-Item -ItemType Directory -Path $interDir -Force | Out-Null }
    Write-Utf8NoBom -Path (Join-Path $interDir "$AgentName.txt") -Content $Content
}

function Update-ManifestEntry {
    param($Manifest, [string]$RelativePath, $State)
    $entry = $Manifest.files | Where-Object { $_.path -eq $RelativePath } | Select-Object -First 1
    if (-not $entry) { return }
    $entry.status = $State.status
    $entry.last_completed_stage = $State.last_completed_stage
    $entry.last_updated = $State.updated_at
    # Add-Member -Force (not plain assignment): on Windows PowerShell 5.1,
    # a ConvertFrom-Json PSCustomObject throws "property ... cannot be
    # found" on assignment to a property it doesn't already have -- unlike
    # PowerShell 7's dynamic-add behavior -- and every pre-existing
    # manifest.json entry predates these two fields (confirmed by testing
    # plain assignment against a real ConvertFrom-Json object first; it
    # failed). -Force makes this the same call whether the property is
    # being added for the first time or just updated on a later run.
    # Previously these lived only in each file's own states/*.state.json --
    # manifest.json itself had no way to say where a completed file's
    # report landed or why a blocked one failed without opening that
    # separate file.
    $entry | Add-Member -NotePropertyName "blocker_or_error" -NotePropertyValue $State.blocker_or_error -Force
    $entry | Add-Member -NotePropertyName "output_references" -NotePropertyValue $State.output_references -Force
    $entry.token_usage.run_total_tokens = $State.token_usage.run_total_tokens
    $entry.token_usage.run_total_elapsed_seconds = $State.token_usage.run_total_elapsed_seconds
    foreach ($agentName in $StageAgents + "file_queue_orchestrator_agent") {
        if ($entry.token_usage.agents.($agentName) -and $State.token_usage.agents.($agentName)) {
            $src = $State.token_usage.agents.($agentName)
            $dst = $entry.token_usage.agents.($agentName)
            $dst.model_name = $src.model_name
            $dst.started_at = $src.started_at
            $dst.ended_at = $src.ended_at
            $dst.elapsed_seconds = $src.elapsed_seconds
            $dst.total_tokens = $src.total_tokens
        }
    }
}

function Write-Checkpoint {
    param($Manifest, [string]$RelativePath, [string]$StateFileRelative, [string]$LastStage, [string]$Status)
    $counts = @{ queued = 0; in_progress = 0; blocked = 0; completed = 0; failed = 0 }
    foreach ($f in $Manifest.files) {
        if ($counts.ContainsKey($f.status)) { $counts[$f.status]++ }
    }
    $stamp = Get-UtcNowStamp
    $checkpoint = [ordered]@{
        checkpoint_id        = "$($stamp -replace ':', '-')-checkpoint"
        created_at           = $stamp
        run_id               = $Manifest.run_id
        last_processed_file  = [ordered]@{
            path                 = $RelativePath
            state_file           = $StateFileRelative
            last_completed_stage = $LastStage
            status               = $Status
        }
        queue_progress       = [ordered]@{
            total_files = $Manifest.files.Count
            completed   = $counts.completed
            in_progress = $counts.in_progress
            queued      = $counts.queued
            blocked     = $counts.blocked
            failed      = $counts.failed
        }
        next_action          = "resume_from_last_completed_stage"
    }
    $path = Join-Path $CheckpointsDir "$($stamp -replace ':', '-')-checkpoint.json"
    Write-Utf8NoBom -Path $path -Content (($checkpoint | ConvertTo-Json -Depth 10) + "`n")
}

function Invoke-Stage {
    param(
        [string]$AgentName, [string]$SystemPrompt, [string]$UserContent,
        [string]$ModelName, $State, [datetime]$DeadlineUtc
    )
    $stageIdx = [array]::IndexOf($StageAgents, $AgentName)
    $stageLabel = if ($stageIdx -ge 0) { "[stage $($stageIdx + 1)/$($StageAgents.Count)] $AgentName" } else { $AgentName }
    # Each event below is a single complete Write-Host call (no -NoNewline
    # split across two calls) so that two workers' lines can never end up
    # glued together mid-line when their output interleaves.
    Log "    $stageLabel ..." "DarkGray"

    # This call's own timeout is however much of the file's overall stall
    # budget is left (floored at MinStageTimeoutSeconds so a nearly-exhausted
    # budget doesn't hand the HTTP call an unusably tiny timeout), capped by
    # -TimeoutSec as an absolute outer ceiling.
    $remainingBudget = ($DeadlineUtc - (Get-Date).ToUniversalTime()).TotalSeconds
    $callTimeoutSec = [Math]::Max($MinStageTimeoutSeconds, [Math]::Min($remainingBudget, $TimeoutSec))

    $startedAt = Get-Date
    try {
        $result = Invoke-OllamaChat -SystemPrompt $SystemPrompt -UserContent $UserContent `
            -BaseUrl $OllamaUrl -ModelName $ModelName -Temp $Temperature `
            -MaxTokens $MaxTokensPerStage -Timeout $callTimeoutSec `
            -HeartbeatLabel "    $stageLabel" -HeartbeatSeconds $HeartbeatSeconds
    }
    catch {
        Set-AgentTiming -State $State -AgentName $AgentName -ModelName $ModelName -StartedAt $startedAt -EndedAt (Get-Date) -Usage $null
        Log "    $stageLabel FAILED after $([Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))s" "Red"
        throw "[$AgentName] $($_.Exception.Message)"
    }
    $endedAt = Get-Date
    Set-AgentTiming -State $State -AgentName $AgentName -ModelName $ModelName -StartedAt $startedAt -EndedAt $endedAt -Usage $result.Usage
    Log ("    $stageLabel done ({0}s, {1} tokens)" -f [Math]::Round(($endedAt - $startedAt).TotalSeconds, 1), $result.Usage.total_tokens) "DarkGray"
    return $result.Content
}

function Invoke-FileAnalysis {
    param($Manifest, $Entry, [string]$ModelName)

    $relativePath = $Entry.path
    # Top-level safety net around this whole function: anything not already
    # handled by the attemptLoop's own catch below (e.g. Read-State failing
    # because Entry.state_file points at a path that no longer exists -- this
    # can happen if another worker/process concurrently moved this file's
    # state.json between when this worker's manifest snapshot was read and
    # when it got around to processing this entry) used to be unhandled and
    # crash the ENTIRE worker process, abandoning every other file still left
    # in its queue -- exactly what happened when three worker processes ended
    # up contending for the same queue at once. Now it just skips this one
    # file and the worker moves on to the next.
    try {
    $sourcePath = Join-Path $Root ($relativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Log "  -> SKIP (source file no longer exists): $relativePath" "DarkGray"
        return
    }
    $sourceFile = Get-Item -LiteralPath $sourcePath

    # The manifest's recorded state_file can go stale relative to reality
    # when a prior run's Save-Manifest crashed AFTER the physical move
    # (Move-CompletedStateFile/Move-BlockedStateFile) but BEFORE persisting
    # that move to manifest.json -- confirmed after the File.Replace($null)
    # bug: files ended up genuinely "completed"/"blocked" on disk while
    # manifest.json still pointed at their old, now-missing flat-folder
    # path, and every subsequent run hit "Cannot find path ... state.json"
    # and permanently SKIPped that file. Rather than getting stuck forever,
    # look the file up by its state-file leaf name under states/done/ and
    # states/blocked/ and repoint the entry at whichever one actually exists.
    if (-not (Test-Path -LiteralPath (Get-StatePath $Entry.state_file))) {
        $leaf = Split-Path -Leaf $Entry.state_file
        $found = @($StatesDoneDir, $StatesBlockedDir) | ForEach-Object { Join-Path $_ $leaf } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $found) {
            Log "  -> SKIP (state file missing -- not found in done/ or blocked/ either): $relativePath" "Red"
            return
        }
        $relDir = if ((Split-Path -Parent $found) -ieq $StatesDoneDir) { "done" } else { "blocked" }
        $Entry.state_file = ".analysis-state/states/$relDir/$leaf"
        $recovered = Read-State -StateFileRelative $Entry.state_file
        if ($recovered.status -in @("completed", "blocked")) {
            Log "  Manifest was stale (pointed at a since-moved/missing state file) -- resyncing to its actual $($recovered.status) result: $relativePath" "DarkCyan"
            Update-ManifestEntry -Manifest $Manifest -RelativePath $relativePath -State $recovered
            return
        }
        Log "  Repointed stale manifest entry to its actual (in-progress) state file: $($Entry.state_file)" "DarkCyan"
    }

    $state = Read-State -StateFileRelative $Entry.state_file
    $state.status = "in_progress"
    if (-not $state.started_at) { $state.started_at = Get-UtcNowStamp }
    $state.blocker_or_error = $null

    $code = Read-LegacySourceText -Path $sourcePath
    $schema = Get-SchemaContext -SourceFile $sourceFile
    $totalChars = $code.Length + $(if ($schema) { $schema.Length } else { 0 })
    if ($MaxContentChars -gt 0 -and $totalChars -gt $MaxContentChars) {
        $state.status = "blocked"
        $state.blocker_or_error = "Source (+schema) is $totalChars chars, exceeds MaxContentChars=$MaxContentChars"
        $state.next_action = "increase_MaxContentChars_or_split_file"
        $state.updated_at = Get-UtcNowStamp
        Save-State -StateFileRelative $Entry.state_file -State $state
        Update-ManifestEntry -Manifest $Manifest -RelativePath $relativePath -State $state
        Move-BlockedStateFile -Entry $Entry -StateFileRelative $Entry.state_file | Out-Null
        Log "  -> SKIP (too large: $totalChars chars): $relativePath" "Magenta"
        return
    }

    $outRelDir = Get-SanitizedRelativeDir -RelativePath $relativePath
    $outRelPosix = $outRelDir -replace '\\', '/'
    $outDir = Join-Path $OutputsDir $outRelDir
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $leafName = $sourceFile.Name
    # Keep a copy of the original source alongside its generated analysis so
    # each output folder is self-contained (readable without the source tree).
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $outDir $leafName) -Force

    # Resume: skip stages already recorded as complete for this file.
    $resumeIndex = 0
    if ($state.last_completed_stage) {
        $idx = [array]::IndexOf($StageAgents, $state.last_completed_stage)
        if ($idx -ge 0) { $resumeIndex = $idx + 1 }
    }

    # $sanitized stays its own variable (the sanitizer is one of the two
    # bespoke endpoint stages); every uniform middle stage's result is keyed
    # by stage name in $results instead of one hand-declared variable each -
    # a new entry in pipeline_stages.ps1's $PipelineStages needs no matching
    # declaration here.
    $sanitized = $null
    $results = @{}

    # Rehydrate prior-stage text from intermediates when resuming past stage 0,
    # so a resumed run doesn't need to recall lost in-memory context.
    $interDir = Join-Path $outDir "intermediates"
    function Get-SavedStage([string]$name) {
        $p = Join-Path $interDir "$name.txt"
        if (Test-Path -LiteralPath $p) { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 }
        return $null
    }
    if ($resumeIndex -gt 0) {
        $sanitized = Get-SavedStage $SanitizerStageName
        for ($i = 0; $i -lt $PipelineStages.Count; $i++) {
            if ($resumeIndex -gt ($i + 1)) {
                $results[$PipelineStages[$i].Name] = Get-SavedStage $PipelineStages[$i].Name
            }
        }
        if (-not $sanitized) {
            # Intermediate file missing (e.g. deleted by hand); restart from stage 0.
            $resumeIndex = 0
        }
    }

    # resumeIndex can reach $StageAgents.Count when the prior attempt got as far as
    # recording the final stage as "last completed" but still failed there (e.g. the
    # architecture_spec_writer produced invalid JSON) -- that retry re-runs only the
    # final stage, so report it as such instead of an out-of-range "stage 10/9 ()".
    if ($resumeIndex -ge $StageAgents.Count) {
        Log "  Retrying final stage ($($StageAgents[$StageAgents.Count - 1]))" "DarkCyan"
    } else {
        Log "  Resuming from stage $($resumeIndex + 1)/$($StageAgents.Count) ($($StageAgents[$resumeIndex]))" "DarkCyan"
    }

    # Stall guard: this file's total budget is StallMultiplier times the
    # current estimate (see Get-EstimatedFileSeconds). Budget is charged
    # against time spent during THIS invocation only -- state.token_usage.
    # run_total_elapsed_seconds is cumulative across every past attempt this
    # file has ever had (including old, unrelated blocks from days ago), so
    # using that total directly would make an already-retried file look
    # "over budget" the instant a fresh attempt starts, even though nothing
    # is actually stuck this time. elapsedBeforeThisCall snapshots that
    # historical total so only the delta accrued just now counts. Each
    # Invoke-Stage call above is handed the resulting deadline and self-
    # times-out via its own HTTP call's -TimeoutSec once the budget runs
    # out, rather than this script needing to interrupt a call from outside.
    $fileBudgetSeconds = $StallMultiplier * (Get-EstimatedFileSeconds)
    $elapsedBeforeThisCall = [double]$state.token_usage.run_total_elapsed_seconds

    $attempt = 0
    $ollamaDownAttempts = 0
    :attemptLoop while ($true) {
        $marginThisAttempt = if ($attempt -gt 0) { $StallRetryMarginSeconds } else { 0 }
        $elapsedThisCall = [double]$state.token_usage.run_total_elapsed_seconds - $elapsedBeforeThisCall
        $budgetRemainingNow = [Math]::Max($fileBudgetSeconds + $marginThisAttempt - $elapsedThisCall, $MinStageTimeoutSeconds)
        $fileDeadlineUtc = (Get-Date).ToUniversalTime().AddSeconds($budgetRemainingNow)

    try {
        if ($resumeIndex -le 0) {
            $userContent = "CODE:`n$code"
            if ($schema) { $userContent += "`n`nSCHEMA (DDL):`n$schema" }
            $sanitized = Invoke-Stage -AgentName $SanitizerStageName -SystemPrompt $SanitizerSystemPrompt -UserContent $userContent -ModelName $ModelName -State $state -DeadlineUtc $fileDeadlineUtc
            Save-Intermediate -OutDir $outDir -AgentName $SanitizerStageName -Content $sanitized
            $state.last_completed_stage = $SanitizerStageName; $state.updated_at = Get-UtcNowStamp
            Save-State -StateFileRelative $Entry.state_file -State $state
        }

        # Uniform middle stages (business_domain_extractor through
        # narrative_writer): each composes its declared inputs from
        # $sanitized/$results, calls the model once, saves the intermediate,
        # and optionally writes a named sibling output file (diagram.mmd,
        # <file>.md). See pipeline_stages.ps1 for what each stage actually
        # consumes - adding a stage here means adding one entry there, not
        # another hand-written block like this used to be, one per stage.
        for ($i = 0; $i -lt $PipelineStages.Count; $i++) {
            $stage = $PipelineStages[$i]
            if ($resumeIndex -gt ($i + 1)) { continue }

            $parts = foreach ($inputSpec in $stage.Inputs) {
                $value = if ($inputSpec.Stage -eq $SanitizerStageName) { $sanitized } else { $results[$inputSpec.Stage] }
                "$($inputSpec.Label):`n$value"
            }
            $userContent = $parts -join "`n`n"

            $systemPrompt = Get-Variable -Name $stage.SystemPromptVar -ValueOnly
            $output = Invoke-Stage -AgentName $stage.Name -SystemPrompt $systemPrompt -UserContent $userContent -ModelName $ModelName -State $state -DeadlineUtc $fileDeadlineUtc
            Save-Intermediate -OutDir $outDir -AgentName $stage.Name -Content $output
            $results[$stage.Name] = $output
            $state.last_completed_stage = $stage.Name; $state.updated_at = Get-UtcNowStamp
            Save-State -StateFileRelative $Entry.state_file -State $state
            if ($stage.SiblingOutput) {
                $siblingName = & $stage.SiblingOutput $leafName
                Write-Utf8NoBom -Path (Join-Path $outDir $siblingName) -Content (Remove-CodeFence $output)
            }
        }

        # Final synthesis (architecture_spec_writer): the one stage whose
        # output is parsed/repaired/validated as JSON and decides completion
        # vs. blocking - genuinely one-of-a-kind, stays hand-written.
        $domain = $results['business_domain_extractor']
        $structure = $results['source_ast_structural_mapper']
        $logic = $results['business_logic_extractor']
        $security = $results['security_compliance_analyst']
        $performance = $results['performance_scalability_analyst']
        $testing = $results['test_validation_analyst']
        $finalContext = "FILE PATH: $relativePath`n`nBUSINESS DOMAIN:`n$domain`n`nSTRUCTURAL BREAKDOWN:`n$structure`n`nBUSINESS LOGIC:`n$logic`n`nSECURITY FINDINGS:`n$security`n`nPERFORMANCE FINDINGS:`n$performance`n`nTEST VALIDATION FINDINGS:`n$testing"
        if ($finalContext.Length -gt $MaxFinalContextChars) {
            throw "[architecture_spec_writer] Chained context too large: $($finalContext.Length) chars > MaxFinalContextChars=$MaxFinalContextChars"
        }
        $rawReport = Invoke-Stage -AgentName $FinalSynthesisStageName -SystemPrompt $ArchitectureSpecSystemPrompt -UserContent $finalContext -ModelName $ModelName -State $state -DeadlineUtc $fileDeadlineUtc
        Save-Intermediate -OutDir $outDir -AgentName $FinalSynthesisStageName -Content $rawReport

        $outputRefs = @()
        try {
            $parsed = (Repair-JsonTruncation (Repair-MismatchedContainerClosers (Repair-UnescapedEmbeddedQuotes (Repair-JsonEscapes (Remove-CodeFence $rawReport))))) | ConvertFrom-Json
            $parsed.module_metadata.file_path = $relativePath
            # token_usage is API call metadata the model has no way to know about
            # itself -- injected from this file's own already-tracked processing
            # history instead of being requested in the prompt at all. Add-Member
            # -Force (not plain assignment): a ConvertFrom-Json object doesn't
            # already have this property, and plain assignment to a
            # not-yet-existing property throws under Windows PowerShell 5.1 (same
            # reasoning as Update-ManifestEntry's blocker_or_error/
            # output_references assignments below).
            $parsed | Add-Member -NotePropertyName token_usage -NotePropertyValue $state.token_usage -Force
            $reportFileName = "$leafName.json"
            $reportPath = Join-Path $outDir $reportFileName
            Write-Utf8NoBom -Path $reportPath -Content (($parsed | ConvertTo-Json -Depth 10) + "`n")
            $outputRefs += ".analysis-state/outputs/$outRelPosix/$reportFileName"
            $state.status = "completed"
            $state.next_action = "none"
        }
        catch {
            $rawFileName = "$leafName.raw.txt"
            $rawPath = Join-Path $outDir $rawFileName
            Write-Utf8NoBom -Path $rawPath -Content $rawReport
            $outputRefs += ".analysis-state/outputs/$outRelPosix/$rawFileName"
            $state.status = "blocked"
            $state.blocker_or_error = "architecture_spec_writer output was not valid JSON: $($_.Exception.Message)"
            $state.next_action = "retry_from_architecture_spec_writer"
        }

        foreach ($stage in $PipelineStages | Where-Object { $_.SiblingOutput }) {
            $siblingName = & $stage.SiblingOutput $leafName
            if (Test-Path -LiteralPath (Join-Path $outDir $siblingName)) {
                $outputRefs += ".analysis-state/outputs/$outRelPosix/$siblingName"
            }
        }
        $state.last_completed_stage = $FinalSynthesisStageName
        $state.output_references = $outputRefs
        $state.updated_at = Get-UtcNowStamp
        Save-State -StateFileRelative $Entry.state_file -State $state
        Update-ManifestEntry -Manifest $Manifest -RelativePath $relativePath -State $state
        $finalStateFile = $Entry.state_file
        if ($state.status -eq "completed") {
            $finalStateFile = Move-CompletedStateFile -Entry $Entry -StateFileRelative $Entry.state_file
        } elseif ($state.status -eq "blocked") {
            $finalStateFile = Move-BlockedStateFile -Entry $Entry -StateFileRelative $Entry.state_file
        }
        Write-Checkpoint -Manifest $Manifest -RelativePath $relativePath -StateFileRelative $finalStateFile -LastStage $state.last_completed_stage -Status $state.status
        Log "  -> $($state.status): $relativePath" $(if ($state.status -eq "completed") { "Green" } else { "Yellow" })
        if ($state.token_usage.run_total_elapsed_seconds -gt 0) {
            $script:WorkerFileSecondsHistory.Add([double]$state.token_usage.run_total_elapsed_seconds)
        }
        break attemptLoop
    }
    catch {
        $isStall = (Get-Date).ToUniversalTime() -ge $fileDeadlineUtc
        $isOllamaDown = Test-IsTransientOllamaError -Message $_.Exception.Message
        if ($isStall -and $attempt -eq 0) {
            Log "  Stalled: $relativePath exceeded its $([Math]::Round($budgetRemainingNow, 0))s budget -- stopping '$ModelName' and retrying with +${StallRetryMarginSeconds}s margin" "Red"
            Restart-OllamaInstance -BaseUrl $OllamaUrl -ModelKey $ModelName | Out-Null
            $attempt++
            continue attemptLoop
        }
        if ($isOllamaDown -and $ollamaDownAttempts -lt $OllamaDownMaxRetries) {
            $ollamaDownAttempts++
            Log "  Ollama isn't answering ($($_.Exception.Message)) -- waiting ${OllamaDownWaitSeconds}s then restarting '$ModelName' and retrying $relativePath (attempt $ollamaDownAttempts/$OllamaDownMaxRetries)" "Red"
            Start-Sleep -Seconds $OllamaDownWaitSeconds
            Restart-OllamaInstance -BaseUrl $OllamaUrl -ModelKey $ModelName | Out-Null
            $attempt++
            continue attemptLoop
        }
        $state.status = "blocked"
        $state.blocker_or_error = if ($isOllamaDown) {
            "Ollama still not answering after $OllamaDownMaxRetries restart attempts: $($_.Exception.Message)"
        } elseif ($isStall) {
            "Stalled twice (exceeded budget even after model reload): $($_.Exception.Message)"
        } else {
            $_.Exception.Message
        }
        $state.next_action = "retry_from_$($state.last_completed_stage)"
        $state.updated_at = Get-UtcNowStamp
        Save-State -StateFileRelative $Entry.state_file -State $state
        Update-ManifestEntry -Manifest $Manifest -RelativePath $relativePath -State $state
        $blockedStateFile = Move-BlockedStateFile -Entry $Entry -StateFileRelative $Entry.state_file
        Write-Checkpoint -Manifest $Manifest -RelativePath $relativePath -StateFileRelative $blockedStateFile -LastStage $state.last_completed_stage -Status $state.status
        Log "  -> BLOCKED: $relativePath :: $($state.blocker_or_error)" "Red"
        break attemptLoop
    }
    }
    }
    catch {
        Log "  -> SKIP (unexpected error, file left as-is for a future run): $relativePath :: $($_.Exception.Message)" "Red"
    }
}

function Main {
    foreach ($path in @($CheckpointsDir, $OutputsDir)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    }

    if ($WorkerCount -gt 1 -and ($WorkerIndex -lt 0 -or $WorkerIndex -ge $WorkerCount)) {
        throw "WorkerIndex must be between 0 and WorkerCount-1 (got WorkerIndex=$WorkerIndex, WorkerCount=$WorkerCount)"
    }

    if ($DryRun) {
        $manifest = Read-Manifest
        $eligible = @($manifest.files | Where-Object { $_.status -in @("queued", "blocked", "in_progress") })
        $preview = if ($Limit -gt 0) { @($eligible | Select-Object -First $Limit) } else { $eligible }
        Log "Would process $($preview.Count) file(s) (of $($eligible.Count) eligible in the shared queue):" "Cyan"
        foreach ($entry in $preview) {
            $resumeNote = if ($entry.last_completed_stage) { "resume after $($entry.last_completed_stage)" } else { "start from stage 1" }
            Log "  [$($entry.status)] $($entry.path) -- $resumeNote"
        }
        return
    }

    if (-not $NoAutoStart) {
        Start-OllamaInstanceIfNeeded -BaseUrl $OllamaUrl -CudaDevice $CudaVisibleDevices -ModelsPath $OllamaModelsPath -ModelKey $Model
    }

    $modelName = $Model
    Log "Using model: $modelName" "Cyan"
    Log "Pulling files from the shared queue as they become available (no fixed partition -- an idle worker helps with whatever's left instead of stopping once its own slice is done)." "Cyan"

    # No fixed per-worker slice: each iteration atomically claims whichever
    # eligible file is next in the shared manifest (see Request-NextFile), so a
    # worker that finishes faster than its peers -- a smaller file, a faster
    # GPU, or simply finishing earlier -- immediately picks up more of THEIR
    # remaining work instead of exiting while they're still busy.
    $processedCount = 0
    while ($Limit -le 0 -or $processedCount -lt $Limit) {
        $claim = Request-NextFile -StaleSeconds $StaleInProgressSeconds
        if (-not $claim) {
            if ($processedCount -eq 0) { Log "Nothing to process: no queued/blocked/in_progress files in the manifest." "Green" }
            break
        }
        $processedCount++
        Log "[claimed $processedCount] $($claim.Entry.path)" "Yellow"
        Invoke-FileAnalysis -Manifest $claim.Manifest -Entry $claim.Entry -ModelName $modelName
        Save-Manifest -Manifest $claim.Manifest -UpdatedPath $claim.Entry.path
    }

    $finalManifest = Read-Manifest
    $completed = @($finalManifest.files | Where-Object { $_.status -eq "completed" }).Count
    $blocked = @($finalManifest.files | Where-Object { $_.status -eq "blocked" }).Count
    Log ""
    Log "--- Run summary ---"
    Log "Processed this run : $processedCount"
    Log "Completed (total)  : $completed"
    Log "Blocked (total)    : $blocked"
    Log ""
    & (Join-Path $PSScriptRoot "queue_eta.ps1") -Workers $WorkerCount
}

try {
    Main
}
finally {
    Remove-Item -LiteralPath $LockFilePath -Force -ErrorAction SilentlyContinue
}
