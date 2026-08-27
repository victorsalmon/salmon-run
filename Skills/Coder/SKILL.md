---
name: opencode/workflow/code
description: Coder role workflow — implement tasks from session plans, run tests, and deliver complete solutions.
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Coder Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/workflow/code"

## Purpose
Implement code changes per session plans. Three dispatch variants:
- **Drain loop** (`work-coder` / "Code"): claims plans, implements, commits, pushes, drains the entire `Tasks/Code/` queue with polling.
- **Single-file pass** (`work-code`): processes one connascence group and exits. Orchestrator-dispatched.
- **Namespace pass** (`work-code-namespace` / "Code Namespace"): completes one namespace end-to-end - implements all plans, handles review feedback, waits for review completion, exits only when namespace is fully in `Tasks/Complete/`.

## Trigger
- User says "Code" (drain loop)
- User says "Code Namespace" (namespace pass)
- An orchestrator dispatches `work-code` or `work-code-namespace` from opencode.json

## Workflow steps
See `workflow.md` (this folder) for the full interactive Coder procedure (Phase 1–5, including predictive compaction, re-groom rule, and Drain Queue).

## Sub-skills and tools
- `workflow.md` — full Coder Workflow (Phase 1–5)
- `tools.md` — tool configuration and constraints

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Connascence, Lock Header, Drain Queue)
- `Skills/Workflows/Shared/session-plan-format.md` — plan format spec
- `Skills/Cowork/handoff.md` — handoff and compaction

## Red lines
- **Never `git add -A` or `git commit -a`** — per-file staging only
- **Never push without pulling first** — `Invoke-GitPullSafe` before push
- **Never skip Pester tests** — run git-aware tests before committing
- **Never skip the Lock Header** — every plan file gets a Lock Header on claim

## Changelog
- 2026-07-15: Consolidated 2026-06-12 lessons into main body (Removed dated block)

## Completion
Commit/push are part of the Finale step in `workflow.md` (step 5). After Finale, return to Drain Queue (step 6). After poll exhausts, emit `Status: Completed <task-name>`.


