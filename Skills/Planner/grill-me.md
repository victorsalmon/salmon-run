---
name: opencode/grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when the user wants to stress-test a plan, get grilled on their design, or says "grill me".
type: workflow
trigger: "grill me, Socratic questions, plan decisions, blocking questions"
---

## Core behavior

Interview the user relentlessly about every aspect of this plan until reaching shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer. Ask the questions one at a time. If a question can be answered by exploring the codebase, explore the codebase instead.

## Turn budget

8 total question turns. At turn 8, if more questions remain, emit a check-in: "We've covered 8 question turns. Ready to proceed, or keep grilling? [y/N]". If the user says y/yes/proceed, stop. If n/no, reset the convergence streak and continue.

## Convergence check

After each user answer, evaluate against the 5-signal operational definition of "new architectural dimension" (signals a–e below). Track consecutive no-dimension answers. Two consecutive triggers a proceed-prompt: "I think we have shared understanding. Ready to proceed? [y/N/keep grilling]".

## Operational definition of "new architectural dimension"

An answer raises a new dimension if it satisfies at least one of:
- (a) Names a **component** not previously discussed
- (b) Introduces a **constraint** (performance, compliance, SLA, capacity) not previously surfaced
- (c) Names a new **actor or persona** (human role, external system, automated agent)
- (d) Introduces a new **data type or entity** (schema, persistent state, message type)
- (e) **Contradicts** a prior answer requiring re-litigation of an architectural decision

## Codebase-exploration substitution

Up to 1 Read or Grep call per turn, used to either answer the candidate follow-up directly from code (skip the question) or surface a contradiction between the user's stated claim and the codebase. On read failure, continue without the cross-reference — do not abort.

## Fuzzy-term sharpening

When the user uses an overloaded term, identify the ambiguity, propose a canonical term, and ask for confirmation in the next turn before incorporating it into any decision.

## Edge-case probing

When discussing a domain relationship, state transition, or data flow, probe with one concrete edge case (e.g., "what happens when X occurs while Y is in state Z?"). One probe per relationship per session.

## Coupling isolation questions

When the work touches multiple files or concerns, ask these to ensure plans are well-isolated for parallel dispatch:

- "Which files will this work touch?" — probe for the complete `Files:` list before writing plans.
- "Are there shared files (interfaces, configs, AGENTS.md) that multiple plans will modify?" — if yes, isolate the shared file into a prerequisite plan.
- "Can the work be split into independent plans that touch disjoint files?" — maximize parallelism.
- "What's the connascence graph? Which plans must be sequential vs parallel?" — sketch the dependency DAG.

If the user names a new shared file that creates a coupling point, that counts as signal (a) — names a new component — for convergence-tracking purposes.

## Sizing questions

After the coupling analysis, validate that each planned session fits under the 250K token cap:

- "Roughly how many tokens will the coder consume for each plan?" — apply the Token Estimation Heuristic in `Skills/Planner/workflow.md`.
- "Does any single plan exceed 200K estimated tokens?" — if yes, split it.
- "Are the plans roughly equal in size?" — prefer equal-size slices over one large + several small.

## Termination priority

Convergence-check proceed > turn-8 check-in > user request to stop. The first hit wins.

## Red lines

- Do not proceed past 8 turns without convergence
- Always provide recommended answer first
- Never ask multiple questions in a single turn
- If the codebase can answer the question, explore it instead of asking

## Cross-references

- `Skills/Planner/SKILL.md` — Plan role overview
- `Skills/Planner/workflow.md` — full Planner workflow
- `Skills/Workflows/Shared/session-plan-format.md` — plan format spec

### Lessons Learned — 2026-06-14

Canonicalized as an ORCHESTRATOR skill. Preserved original structure (8 turns, 2-streak, 5-signal new-dimension definition). Added project frontmatter, Red lines section, and project cross-refs.

### Lessons Learned — 2026-07-14

Added Coupling isolation questions and Sizing questions sections (per plan-role-01). Coupling questions probe for the `Files:` list and connascence DAG before writing plans. Sizing questions validate each plan fits under the 250K cap. New shared file = convergence signal (a).
