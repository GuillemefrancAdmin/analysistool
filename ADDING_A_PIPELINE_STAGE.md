# Adding a new analysis stage — instructions for an AI assistant

This file is written for an AI assistant (Claude Code, Copilot, or similar) asked to add a new stage to the legacy-source-analysis pipeline. It is the accumulated result of actually doing this twice: once the hard way (`add-narrative-writer-agent`, which hand-edited two files and hit two real bugs along the way), and once after `normalize-pipeline-stages` made it a data change instead of a code change. Follow this and adding a stage should take minutes, not hours.

**Do not start editing files before reading "Before you touch anything" below.**

---

## 1. Understand the shape of the pipeline first

Ten stages run per file, in fixed order, each a separate call to a local Ollama model:

```
sanitizer_context_ingestion_agent
    ↓
business_domain_extractor ──┐
    ↓                       │
source_ast_structural_mapper│
    ↓                       │  (these 6 stages' results all feed
business_logic_extractor    │   diagram_designer_context_visualizer
    ↓                       │   and narrative_writer independently -
security_compliance_analyst │   neither depends on the other)
    ↓                       │
performance_scalability_analyst
    ↓                       │
test_validation_analyst ────┘
    ↓                       ↓
diagram_designer_    narrative_writer
context_visualizer
    ↓                       ↓
    └───────────┬───────────┘
                ↓
     architecture_spec_writer   (final JSON synthesis)
```

There are **two kinds of stages**, and which kind your new stage is determines everything else:

- **Uniform middle stages** — everything from `business_domain_extractor` through `narrative_writer`. Each one: composes a prompt from some subset of prior stages' results, calls the model once, saves the result as an intermediate, optionally writes one extra named file alongside it (`diagram.mmd`, `<file>.md`). **A new analysis stage is almost certainly this kind.** This is the case this guide covers in detail.
- **Bespoke endpoint stages** — `sanitizer_context_ingestion_agent` (reads the raw source file, not prior results) and `architecture_spec_writer` (parses/repairs/validates JSON output, decides `completed` vs `blocked`). These are genuinely one-of-a-kind and stay hand-written. You will almost never need to touch these for a new *analysis* stage — only if you're changing what gets sanitized or changing the final report's JSON schema, which is a different task from this guide.

**Key files:**

| File | Role |
|---|---|
| `scripts/pipeline_stages.ps1` | The single source of truth: `$PipelineStages` (the ordered middle-stage table), `$SanitizerStageName`/`$FinalSynthesisStageName`, `Get-AllAgentNames`, `New-EmptyAgentUsage`. **This is almost the only file you need to edit for a new stage.** |
| `scripts/run_analysis_pipeline.ps1` | Executes the chain. Dot-sources `pipeline_stages.ps1`. Contains the system prompt text for every middle stage as a top-level `$XxxSystemPrompt` variable, plus the hand-written sanitizer and final-synthesis blocks. |
| `scripts/generate_analysis_queue.ps1` | Discovers source files, seeds new manifest/state entries. Also dot-sources `pipeline_stages.ps1` — you should never need to edit this file for a new stage. |
| `scripts/backfill_new_stage.ps1` | Propagates a new stage across files that already completed the chain before it existed. You'll run this, not edit it. |
| `skills/<stage-name>/SKILL.md` | Documents the new agent's role. One per stage, kebab-case directory name. |
| `openspec/specs/legacy-source-analysis-agents/spec.md` | The spec-of-record for the agent chain. Update it (see §5). |

---

## 2. Before you touch anything

**Check for a live pipeline run first:**

```powershell
Get-ChildItem .analysis-state\locks\*.lock -ErrorAction SilentlyContinue
```

For each lock file found, check whether its recorded PID is still alive (`Get-Process -Id <pid>`). If a worker is genuinely running, **stop it before editing `run_analysis_pipeline.ps1` or `pipeline_stages.ps1`**:

```powershell
.\scripts\stop_analysis_pipeline.ps1
```

Editing these files while a worker has them loaded won't crash that already-running process (PowerShell parses the whole script into memory at launch), but if the parallel orchestrator auto-restarts a crashed worker mid-edit, that restart will load a syntactically broken or half-finished script into a multi-hour production run. Don't take the risk — stop, edit, verify, restart.

---

## 3. Write the system prompt

Add a new top-level `$<Name>SystemPrompt` variable in `run_analysis_pipeline.ps1`, next to the other stage prompts (search for `$DiagramSystemPrompt` or `$NarrativeWriterSystemPrompt` to find the block). Follow the existing pattern:

```powershell
$YourNewStageSystemPrompt = @'
You are the <Role Name> Agent for a legacy modernization pipeline. You receive <exactly what inputs you're about to declare in step 4>. Your job:
1. ...
2. ...
Output ONLY <the exact expected output shape - plain text under labeled sections, a single fenced code block, whatever it is>. No preamble, no commentary outside that.
'@
```

Read 2-3 existing prompts first (`$SecuritySystemPrompt`, `$DiagramSystemPrompt`, `$NarrativeWriterSystemPrompt`) to match the house style: numbered responsibilities, an explicit "Output ONLY..." instruction, and — critically — an explicit statement of what *not* to do if your stage's job could be confused with an existing stage's (see how `$NarrativeWriterSystemPrompt` explicitly says not to restate security/performance/quality findings, since those already have their own report sections).

Static analysis will flag this new variable as "assigned but never used" once you finish step 4 — that's a known false positive (see the comment above `$BusinessDomainSystemPrompt` in the file). The registry looks it up by name at runtime via `Get-Variable`, which static analysis can't trace.

---

## 4. Add the stage to the registry

Open `scripts/pipeline_stages.ps1`. Add one entry to `$PipelineStages`, in whatever chain position makes sense (it does not need to be at the end — insertion order is entirely up to where you place it in this array; nothing elsewhere hardcodes positions).

```powershell
@{
    Name            = "your_new_stage_name"          # snake_case, becomes the agent name everywhere
    SystemPromptVar = "YourNewStageSystemPrompt"      # must match the variable name from step 3 exactly
    Inputs          = @(
        @{ Stage = "business_domain_extractor"; Label = "BUSINESS DOMAIN" }
        @{ Stage = "business_logic_extractor"; Label = "BUSINESS LOGIC" }
        # ... whichever prior stages this one actually needs. Order here is
        # the order they'll be concatenated into the prompt.
    )
    # Omit SiblingOutput entirely unless this stage writes an extra file
    # beyond its standard intermediate (see step 5).
}
```

**Choosing `Inputs`:** look at what similar existing stages consume and reuse their exact `Label` text if you're pulling in the same prior stage's result — labels aren't globally fixed per source stage, each *consumer* declares its own label for what it pulls in (e.g. `business_domain_extractor`'s result is labeled `"BUSINESS DOMAIN SUMMARY"` when `source_ast_structural_mapper` consumes it, but `"BUSINESS DOMAIN"` when `diagram_designer_context_visualizer`/`narrative_writer` consume it — both are correct, just historically different). For a genuinely new stage, pick whatever label reads clearly in the composed prompt; there's no requirement to match an existing one if none of the existing consumers pull in the same combination you need.

You can reference `sanitizer_context_ingestion_agent` as an input stage name too (its result is available as `$sanitized`, handled specially since it's not in `$results`) — several existing stages do this (`business_domain_extractor`, `source_ast_structural_mapper`, `business_logic_extractor`, `security_compliance_analyst` all consume the sanitized context directly).

**You do not need to touch `run_analysis_pipeline.ps1`'s execution logic at all.** The generic loop there (`for ($i = 0; $i -lt $PipelineStages.Count; $i++) { ... }`) already handles: resume/rehydration gating, composing the labeled prompt from your `Inputs`, calling the model, saving the intermediate, advancing `last_completed_stage`, and writing your `SiblingOutput` if you declared one. This loop is the entire point of `normalize-pipeline-stages` — a new table entry is a new stage, full stop.

---

## 5. Decide: does this stage need a new output artifact?

Two options, and the choice matters:

- **No new artifact — the stage's result only feeds forward** into a later stage's `Inputs` (e.g. it exists purely to enrich what `architecture_spec_writer` or another downstream stage sees). Nothing further needed; its output is saved as an intermediate automatically and available to any stage whose `Inputs` names it.
- **New standalone sibling file** (the `narrative_writer` pattern) — add `SiblingOutput = { param($LeafName) "some-name.ext" }` to the table entry. Prefer this over adding a field to the JSON report schema: `architecture_spec_writer` already has to compress six stages' findings into ~30 JSON fields on a small local model in one call, and asking it to *also* carry your new content through that same call competes for its output budget — this is exactly why `narrative_writer` was split out as its own stage instead of staying an embedded `markdown_report` field. A sibling file also avoids JSON-escaping a large text blob.

  If you do this, also check whether the web-viewer needs a rendering path for the new file type. `.mmd` (diagram) and `.md` (narrative) already have dedicated handling in `web-viewer/src/outputs.js`/`web-viewer/src/routes/file.js`; a genuinely new file extension would need the equivalent added there.

- **New JSON report field** — only if the content genuinely belongs alongside the structured report (a score, a short enum, a small structured fact) and isn't a large prose blob. If so, you're touching `architecture_spec_writer`'s prompt and `templates/source-code-analysis-schema.json`, which is outside the scope of "adding a stage" — that's editing the bespoke final-synthesis stage's own contract. Tread carefully and re-read that stage's system prompt in full first.

---

## 6. Document the agent

Create `skills/your-new-stage-name/SKILL.md` (kebab-case directory, matching every existing sibling under `skills/`). Copy the structure of an existing one close in spirit to your new stage (`skills/narrative-writer/SKILL.md` for a prose-output stage, `skills/diagram-designer-context-visualizer/SKILL.md` for a structured-artifact stage) and fill in: Role, Mission, Inputs, Responsibilities, Workflow, Expected output, any Quality rules, Success criteria. This isn't optional decoration — `legacy-source-analysis-agents`'s "Agent definitions are discoverable" requirement expects exactly one `SKILL.md` per agent name in the chain.

---

## 7. Update the OpenSpec specs

This repo tracks the pipeline's contract in `openspec/`. Use the `openspec-propose` skill/workflow rather than hand-editing `openspec/specs/*/spec.md` directly — go through `proposal.md` → `design.md` → `specs/` deltas → `tasks.md` the same way `add-narrative-writer-agent` and `normalize-pipeline-stages` did (both are in `openspec/changes/archive/` as worked examples if you want to see the pattern end to end).

At minimum, expect to touch:
- `legacy-source-analysis-agents` — the chain grows by one; document the new agent's role/inputs/output the same way `narrative_writer`'s own requirement is documented there.
- `sequential-pipeline-execution` — if your stage changes what a *later* stage receives, or if you're adding a `SiblingOutput`, note it.
- `queue-eta-reporting` — the "N stages" ETA proration count changes.

For a worked example of the whole propose → design → specs → tasks → apply cycle, read `openspec/changes/archive/2026-09-22-add-narrative-writer-agent/` (adding `narrative_writer` itself, the hard way, before this guide existed) and `openspec/changes/normalize-pipeline-stages/` (the refactor that made this guide possible — not yet archived at time of writing; check `openspec list` for its current status).

If this is truly a routine addition, these deltas will be small — most of the spec text (post-`normalize-pipeline-stages`) already describes the mechanism ("the ordered list of stages defined by the shared stage registry") rather than a hardcoded count, specifically so most future stage additions don't need to touch this prose at all.

---

## 8. Test it

1. **Syntax-check both edited files** before running anything:
   ```powershell
   $errors = $null
   [System.Management.Automation.Language.Parser]::ParseFile("scripts\run_analysis_pipeline.ps1", [ref]$null, [ref]$errors) | Out-Null
   $errors  # should be empty
   ```
   Repeat for `pipeline_stages.ps1` if you touched it directly (you always will have).

2. **`-DryRun` first**, always:
   ```powershell
   .\scripts\run_analysis_pipeline.ps1 -DryRun -Limit 3
   ```
   Confirms the queue and resume points look sane before spending real model time.

3. **Run one real file** and inspect the result:
   ```powershell
   .\scripts\run_analysis_pipeline.ps1 -Limit 1
   ```
   Then check: did your stage run and appear in the log at the right position? Does its intermediate exist under `.analysis-state/outputs/<...>/intermediates/<your_stage_name>.txt`? If you added a `SiblingOutput`, does that file exist and read correctly? Is it listed in that file's `output_references` in both the state file and the manifest?

4. **Confirm resumability across the new boundary.** Pick a file whose `last_completed_stage` is the stage immediately before yours, and `-DryRun` it — it should report resuming at your new stage, not skipping past it or re-running earlier stages.

---

## 9. Backfill already-completed files

Files that finished the *old* chain before your stage existed won't automatically pick it up (resume only moves forward from `last_completed_stage`, and their recorded stage is now past your new stage's position). Use the backfill tool rather than hand-editing state files:

```powershell
# Report-only first - always check the count before -Force
.\scripts\backfill_new_stage.ps1 -NewStageName your_new_stage_name

# Then actually rewind them
.\scripts\backfill_new_stage.ps1 -NewStageName your_new_stage_name -Force
```

This finds every `completed` file missing your stage's usage record, rewinds `last_completed_stage` to the stage immediately before yours (looked up automatically from the registry — you don't tell it what the preceding stage is), resets `status` to `queued`, and zeroes the run-total counters — while leaving every earlier stage's recorded history untouched, so the next pipeline run reuses those saved intermediates instead of reprocessing from scratch. It's safe to run while other files are still being actively processed (it only ever touches `completed` entries, which a live worker never holds).

After backfilling, run the pipeline (single-worker `run_analysis_pipeline.ps1` or `run_analysis_pipeline_parallel.ps1` for multiple GPU workers) to actually process the rewound queue.

---

## 10. Known pitfalls (all hit for real in this codebase — don't repeat them)

- **Never write manifest/state JSON with `Out-File -Encoding utf8` or similar.** Windows PowerShell's `utf8` encoding writes a BOM, which breaks the web-viewer's Node-based JSON parsing (`JSON.parse` chokes on a leading BOM byte). Always use the established `Write-Utf8NoBom` pattern (`New-Object System.Text.UTF8Encoding($false)` + `[System.IO.File]::WriteAllText`) — see `scripts/backfill_new_stage.ps1` for a self-contained copy, or `run_analysis_pipeline.ps1`'s own `Write-Utf8NoBom` function.
- **A fresh per-agent `token_usage` record needs all seven fields** (`model_name`, `started_at`, `ended_at`, `elapsed_seconds`, `prompt_tokens`, `completion_tokens`, `total_tokens`) — use `New-EmptyAgentUsage` from `pipeline_stages.ps1`, never hand-roll a hashtable literal. A 5-field version (missing `prompt_tokens`/`completion_tokens`) existed independently in two places in this codebase before `normalize-pipeline-stages` and caused a real crash (`Set-AgentTiming` assigning to a property that doesn't exist throws on Windows PowerShell 5.1 — `ConvertFrom-Json` objects don't support ad-hoc property addition the way PowerShell 7 does).
- **Bulk-writing `manifest.json` must go through the same cross-process mutex** (`"AnalysisPipelineManifestLock"`) `Save-Manifest` uses, if there's any chance a live worker is also writing to it. `backfill_new_stage.ps1` does this correctly — copy its pattern rather than writing the manifest directly if you build another tool that touches it.
- **Don't assume `$PSScriptRoot` is the repo root** in these scripts — it's `scripts/` itself; `$Root`/`Split-Path -Parent $PSScriptRoot` is the repo root. Dot-source `pipeline_stages.ps1` as `Join-Path $PSScriptRoot "pipeline_stages.ps1"`.
- **Check `.analysis-state/locks/` before editing live scripts** (§2) — don't skip this because "it's probably fine."
