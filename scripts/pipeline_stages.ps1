# Single source of truth for the per-file analysis stage roster. Dot-sourced
# by both run_analysis_pipeline.ps1 (which executes the stages) and
# generate_analysis_queue.ps1 (which needs the full agent name list to seed
# each newly-discovered file's token_usage.agents template) so neither script
# maintains its own independent copy of the roster.
#
# Only the "uniform middle" stages -- business_domain_extractor through
# narrative_writer -- are declared here as data. The sanitizer (reads raw
# source, not prior stage results) and the final JSON-synthesis stage (parses/
# repairs/validates its output and decides completion vs. blocking) are each
# genuinely one-of-a-kind and stay hand-written in run_analysis_pipeline.ps1;
# $SanitizerStageName/$FinalSynthesisStageName below are just their names, so
# that script never has to hardcode those literal strings either.

$SanitizerStageName = "sanitizer_context_ingestion_agent"
$FinalSynthesisStageName = "architecture_spec_writer"

# Each entry:
#   Name            - the stage/agent name, used for Invoke-Stage, intermediates,
#                      last_completed_stage, and token_usage.agents.
#   SystemPromptVar  - name of the variable (defined in run_analysis_pipeline.ps1)
#                      holding this stage's system prompt text.
#   Inputs           - ordered list of @{ Stage = <prior stage name>; Label = <exact
#                       label text this stage has always used for that input> }.
#                       The same source stage can carry a different label for
#                       different consumers (e.g. business_domain_extractor's
#                       result is labeled "BUSINESS DOMAIN SUMMARY" for
#                       source_ast_structural_mapper but "BUSINESS DOMAIN" for
#                       diagram_designer_context_visualizer) - preserved here
#                       exactly as each stage already composed it, so this
#                       refactor changes no stage's actual prompt input.
#   SiblingOutput    - optional; for stages that also write a named file
#                       alongside the standard intermediate (diagram.mmd,
#                       <file>.md). A scriptblock taking the file's leaf name
#                       and returning the sibling file's name.
$PipelineStages = @(
    @{
        Name            = "business_domain_extractor"
        SystemPromptVar = "BusinessDomainSystemPrompt"
        Inputs          = @(
            @{ Stage = "sanitizer_context_ingestion_agent"; Label = "SANITISED CODE CONTEXT" }
        )
    },
    @{
        Name            = "source_ast_structural_mapper"
        SystemPromptVar = "StructuralMapperSystemPrompt"
        Inputs          = @(
            @{ Stage = "sanitizer_context_ingestion_agent"; Label = "SANITISED CODE CONTEXT" }
            @{ Stage = "business_domain_extractor"; Label = "BUSINESS DOMAIN SUMMARY" }
        )
    },
    @{
        Name            = "business_logic_extractor"
        SystemPromptVar = "BusinessLogicSystemPrompt"
        Inputs          = @(
            @{ Stage = "sanitizer_context_ingestion_agent"; Label = "SANITISED CODE CONTEXT" }
            @{ Stage = "source_ast_structural_mapper"; Label = "STRUCTURAL BREAKDOWN" }
            @{ Stage = "business_domain_extractor"; Label = "BUSINESS DOMAIN SUMMARY" }
        )
    },
    @{
        Name            = "security_compliance_analyst"
        SystemPromptVar = "SecuritySystemPrompt"
        Inputs          = @(
            @{ Stage = "sanitizer_context_ingestion_agent"; Label = "SANITISED CODE CONTEXT" }
            @{ Stage = "source_ast_structural_mapper"; Label = "STRUCTURAL BREAKDOWN" }
            @{ Stage = "business_logic_extractor"; Label = "BUSINESS LOGIC" }
        )
    },
    @{
        Name            = "performance_scalability_analyst"
        SystemPromptVar = "PerformanceSystemPrompt"
        Inputs          = @(
            @{ Stage = "source_ast_structural_mapper"; Label = "STRUCTURAL BREAKDOWN" }
            @{ Stage = "business_logic_extractor"; Label = "BUSINESS LOGIC" }
        )
    },
    @{
        Name            = "test_validation_analyst"
        SystemPromptVar = "TestValidationSystemPrompt"
        Inputs          = @(
            @{ Stage = "source_ast_structural_mapper"; Label = "STRUCTURAL BREAKDOWN" }
            @{ Stage = "business_logic_extractor"; Label = "BUSINESS LOGIC" }
        )
    },
    @{
        Name            = "diagram_designer_context_visualizer"
        SystemPromptVar = "DiagramSystemPrompt"
        Inputs          = @(
            @{ Stage = "business_domain_extractor"; Label = "BUSINESS DOMAIN" }
            @{ Stage = "source_ast_structural_mapper"; Label = "STRUCTURAL BREAKDOWN" }
            @{ Stage = "business_logic_extractor"; Label = "BUSINESS LOGIC" }
            @{ Stage = "security_compliance_analyst"; Label = "SECURITY FINDINGS" }
            @{ Stage = "performance_scalability_analyst"; Label = "PERFORMANCE FINDINGS" }
            @{ Stage = "test_validation_analyst"; Label = "TEST VALIDATION FINDINGS" }
        )
        SiblingOutput   = { param($LeafName) "diagram.mmd" }
    },
    @{
        Name            = "narrative_writer"
        SystemPromptVar = "NarrativeWriterSystemPrompt"
        Inputs          = @(
            @{ Stage = "business_domain_extractor"; Label = "BUSINESS DOMAIN" }
            @{ Stage = "source_ast_structural_mapper"; Label = "STRUCTURAL BREAKDOWN" }
            @{ Stage = "business_logic_extractor"; Label = "BUSINESS LOGIC" }
            @{ Stage = "security_compliance_analyst"; Label = "SECURITY FINDINGS" }
            @{ Stage = "performance_scalability_analyst"; Label = "PERFORMANCE FINDINGS" }
            @{ Stage = "test_validation_analyst"; Label = "TEST VALIDATION FINDINGS" }
        )
        SiblingOutput   = { param($LeafName) "$LeafName.md" }
    }
)

# The full agent roster in execution order, including the queue orchestrator
# (not itself an LLM stage) and both bespoke endpoint stages. This is what
# generate_analysis_queue.ps1's $AgentNames used to hardcode independently.
function Get-AllAgentNames {
    $names = @("file_queue_orchestrator_agent", $SanitizerStageName)
    $names += $PipelineStages | ForEach-Object { $_.Name }
    $names += $FinalSynthesisStageName
    return $names
}

# The one canonical "empty per-agent token_usage record" shape (the seven
# fields templates/source-code-analysis-schema.json requires). Used for
# seeding a newly-discovered file's state, rebuilding a manifest entry's
# summary, and as the pipeline runner's defensive fallback for an agent not
# yet present in an older state file - previously three independent,
# hand-written copies that had silently drifted out of sync with each other.
function New-EmptyAgentUsage {
    return [ordered]@{
        model_name        = ""
        started_at        = $null
        ended_at          = $null
        elapsed_seconds   = 0
        prompt_tokens     = 0
        completion_tokens = 0
        total_tokens      = 0
    }
}
