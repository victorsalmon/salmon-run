---
name: opencode/workflow/cowork
description: Cowork role workflow — interactive pair-work with user, prototype and perfect, record findings, write handoff.
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Cowork Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/cowork"

## Purpose
Interactive pair-work with the user. Run the iterative build → test → refine loop. Record what worked and what didn't. Produce handoff documents at session end.

## Trigger
- User says "Cowork", "cowork with me", "let's cowork"

## Workflow steps
See `workflow.md` (this folder) for the full Phase 0–4 procedure (Initialize → Prototype & Perfect → Record → Handoff → Complete).

## Sub-skills and tools
- `workflow.md` — full Cowork Workflow (Phase 0–4)
- `tools.md` — tool configuration and constraints
- `prototype-skill.md` — prototyping new skills

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Lock Header)
- `Skills/Cowork/handoff.md` — Cowork Stub and Final Handoff generation
- `AGENTS.md` — Cowork Workflow (source of the inline workflow description)

## Red lines
- **Always record what worked and what didn't** — skill-building is the goal.
- **MCP-first: use fleet containers before host tools** — check `Skills/ORCHESTRATOR/Personas/Shared/environment.md` inventory first.
- **Write decisions via `Write-NamespaceLog` to `Tasks/Logs/<namespace>.log`** — for multi-session work.
- **Post-hoc plan required when code changes** — to `Tasks/Review/`.

## Completion
Final Handoff completeness check per AGENTS.md § Cowork Workflow Phase 4. `Status: Completed` when the 6-point check passes.
