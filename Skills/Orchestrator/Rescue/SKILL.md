---
name: opencode/rescue
description: Rescue role workflow — rescue orphaned plans from crashed agents, clean locks, restore workflow state.
type: mode-workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Rescue Workflow — opencode mode workflow

**Type**: mode-workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json → "opencode/rescue"

## Purpose
Rescue orphaned session plans from crashed agents in `Tasks/Working/`. Single-pass mode — scan for stalled Lock Headers, reclaim files, and return them to the queue.

## Trigger
- User says "Rescue"
- An orchestrator dispatches rescue mode

## Workflow steps
See `workflow.md` (this folder) for the full Rescue procedure.

## Sub-skills and tools
- `workflow.md` — full Rescue Workflow
- `tools.md` — tool configuration and constraints

## Key cross-references
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives (Lock Header, Stalled file handling)

## Red lines
- **Never modify code** — Rescue only moves files and cleans locks.
- **Never enter the drain/poll loop** — single-pass, exit after rescue.
- **Never rescue files locked by a live agent** — check PID files in `Tasks/Logs/agents/`.

## Completion
Inline Completion section in Rescue/workflow.md. `Status: Completed` when orphans rescued and locks cleaned.
