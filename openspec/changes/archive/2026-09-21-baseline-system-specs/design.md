## Context

This change adds no code and makes no architectural decisions — it captures the existing analysistool pipeline (PowerShell orchestration scripts + `skills/*` LLM agent definitions + `.analysis-state/` conventions) as OpenSpec baseline specs, grounded directly in the current implementation. See `proposal.md` for the full capability list and `specs/*/spec.md` for the captured requirements.

## Goals / Non-Goals

**Goals:**
- Establish `openspec/specs/` as an accurate, reviewable record of current pipeline behavior, so future changes have a baseline to diff against.

**Non-Goals:**
- No new functionality, refactor, or architectural change to the pipeline scripts or skills.
- No technical decisions to make or alternatives to weigh — this is transcription of existing, already-running behavior.

## Decisions

None — this change does not alter how the system works, only documents it.

## Risks / Trade-offs

[Spec drifts from implementation as scripts evolve] → Mitigation: future behavior changes to `scripts/*.ps1` or `skills/*` should land as their own OpenSpec change with a MODIFIED-Requirements delta against these baseline specs, keeping `openspec/specs/` authoritative.

## Migration Plan

Not applicable — no runtime artifacts change. Archiving this change moves `specs/*/spec.md` into `openspec/specs/`.
