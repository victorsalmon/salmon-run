---
name: opencode/wayfinder
description: Plan a large, foggy effort as a shared map of decision tickets in Tasks/Wayfinder/, then resolve them one at a time until the route to the destination is clear. Use when the user says /wayfinder, the effort is larger than one session, or the route is unclear.
type: workflow
flavor: opencode
container: opencode
loaded_by: any opencode CLI session
triggers:
  - user
  - model
---

# Wayfinder — Multi-Session Planning

> Adapted from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT License, Copyright 2026 Matt Pocock) for the ORCHESTRATOR local task queue. See `REFERENCE.md` in this directory for the original license, full map/ticket templates, and the concept reference.

A loose idea has arrived, too big for one agent session and wrapped in fog. Wayfinding finds the route, not by charging at the destination. This skill charts the way as a **shared map** in `Tasks/Wayfinder/<effort>/`, then works its **decision tickets** one at a time until the route is clear.

## Plan, don't do

Each ticket resolves a decision. When the map is clear and nothing is left to decide before someone builds the thing, hand off to a normal Plan/Cowork session. Produce decisions, not deliverables, unless the map's **Notes** explicitly say execution is in scope.

## Tracker for this repo

- **Map**: `Tasks/Wayfinder/<effort>/map.md`
- **Tickets**: `Tasks/Wayfinder/<effort>/issues/NN-<slug>.md`, numbered from `01`
- **Research outputs**: `Tasks/Wayfinder/<effort>/research/<slug>.md`
- **Prototypes**: `Tasks/Wayfinder/<effort>/prototypes/<slug>/`
- **Claim**: set `**Status:** claimed`, add `**Agent:** <agentId>`, and prepend a Lock Header (see `Skills/Create/Skill-Authoring/workflow-primitives.md`)
- **Resolve**: append an `## Answer` section, set `**Status:** resolved`, record a one-line decision in the map's `## Decisions so far`
- **Blocking**: `**Blocked by:** 01, 02` in the ticket. A ticket is unblocked when every blocker is `resolved`.
- **Frontier**: open, unblocked, unclaimed tickets. Pick the lowest-numbered ticket.
- **Out of scope**: close the ticket and record it in the map's `## Out of scope`.

## Map and ticket templates

See `REFERENCE.md` for the full map and ticket body templates.

## Ticket types

- **research** (AFK): spawn a `subagent_explore` with a research task; write findings to `research/<slug>.md` and link them.
- **prototype** (HITL): create a rough artifact in `prototypes/<slug>/` and link it.
- **grilling** (HITL): run `Skills/Planner/grill-me.md` in the current session.
- **task** (HITL or AFK): manual work that unblocks a decision; record what was done and the resulting facts.

## Chart the map (first session)

1. Name the destination. Grill the user, then stress-test with `Skills/Planner/consider-alternatives.md`.
2. Map the frontier, breadth-first: surface open decisions and first steps. If there is no fog, stop and use normal Plan mode.
3. Create `Tasks/Wayfinder/<effort>/map.md` with Destination, Notes, Decisions so far, Not yet specified, and Out of scope.
4. Create `issues/01-<slug>.md`, `02-...` for the decisions you can specify now.
5. Fire research subagents for `research` tickets in parallel.
6. Stop. Charting is one session's work.

## Work through the map

1. Load the map.
2. Choose the next frontier ticket (or the one the user named). Claim it.
3. Resolve it using the appropriate ticket type.
4. Record the answer, mark the ticket `resolved`, and append a one-line pointer to the map's `## Decisions so far`.
5. Graduate any `## Not yet specified` fog into new tickets. Move mis-scoped tickets to `## Out of scope`.
6. When the frontier is empty, write a handoff to `Tasks/Handoff/wayfinder-<effort>-complete.md`. If the destination is implementation, create a ready Coder plan in `Tasks/Code/<date>-wayfinder-<effort>-implementation-01.md`.

## Red lines

- Never resolve more than one ticket per session (research subagents are the exception).
- A HITL ticket only resolves through live exchange with the user; do not answer your own grilling questions.
- `task` tickets only unblock decisions; they do not deliver pieces of the destination.
- Do not edit the map or a ticket without claiming it.
- Never `git add -A` or `git commit -a`; stage files per concern and pull-rebase before push.
