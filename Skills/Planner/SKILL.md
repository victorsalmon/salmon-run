---
name: opencode/workflow/plan
description: Planner role workflow — session planning, brainstorming, architecture. Discover → Write → Complete cycle.
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Planner Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/plan"

## Purpose
Run the Planner loop: discover the user's request scope, grill them to resolve blocking decisions, write a self-contained session plan to `~/.salmon/Tasks/Code/`, and complete. The Planner is a single-pass mode — it drains no queue and exits after writing one plan.

## Trigger
- User says "Plan", "I'd like you to plan", "please plan", or "print"
- Single-word "print" command
- An orchestrator dispatches `plan` from opencode.json

## Workflow steps
See `workflow.md` (this folder) for the full Discover → Write → Complete procedure.

## Sub-skills and tools
- `workflow.md` — full Planner Workflow (Phase 1–5)
- `bootstrap.md` — startup sequence
- `tools.md` — tool configuration and constraints
- `brainstorm.md` — brainstorming and ideation
- `consider-alternatives.md` — alternatives analysis
- `Wayfinder/SKILL.md` — multi-session planning across decision tickets

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Connascence, Lock Header, Drain Queue, Shared Spec Change Protocol)
- `Skills/Workflows/Shared/session-plan-format.md` — plan template and format spec
- `Skills/Planner/grill-me.md` — grilling skill (8-turn budget)
- `Skills/Planner/Wayfinder/SKILL.md` — wayfinder for large, foggy efforts
- `Skills/Cowork/handoff.md` — Plan Stub generation for `Tasks/Handoff/`
- **AGENTS.md § Plan output location** — standing rule: all plans written to `~/.salmon/Tasks/Code/`; interactive plans use `Status: proposal`; ExitPlanMode still fires for in-session approval.

## Red lines
- **Never modify code** — Planner writes plans, not code. No script, Dockerfile, or config file edits.
- **Never implement code under Planner identity** — if discovery reveals a bug worth fixing, a missing implementation detail, or any code change, switch to Code mode. The Planner CC does not cover code changes — it only validates plan quality.
- **Never push to git** — commit locally, Coder handles push.
- **Never edit shared files without the FENCE prompt** — Shared Spec Change Protocol applies (present diff to user, wait for `y`).
- **Never exit before the Completion section finishes** — inline CC in `workflow.md` is the only gate.

## Completion
Inline Completion section in `workflow.md` (this folder).
