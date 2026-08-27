# Role Routing — Canonical Reference

> **Audience**: Every persona (BASE, ORCH, VERI) and every opencode workflow loads this file. It is the single canonical source for "which user command maps to which persona/workflow".

Role-routing rules are split across the local CLI (`AGENTS.md § Local CLI Mode-Taking Commands`) and the fleet dispatch (`Skills/Orchestrator/Personas/Shared/protocols.md § Fleet Command Words`). This file consolidates both into one table.

## Local CLI Mode-Taking Commands

When the user runs opencode directly on the dev machine, the following commands dispatch to the named mode:

| Command | Mode | Look for work in |
|---------|------|------------------|
| `"Plan"` / `"plan"` / `"I'd like you to plan"` / `"please plan"` | **Plan** | `Tasks/Handoff/` (Plan Stubs) — ideate, brainstorm, write session plans |
| `"Code"` / `"code"` | **Code** | `Tasks/Code/` — full drain loop. Process all plans and poll for new work. |
| `"Code Namespace"` / `"code-namespace"` | **Code (namespace)** | `Tasks/Code/` — select first eligible namespace, implement all plans end-to-end, exit when namespace fully in `Tasks/Complete/`. |
| `"Review"` / `"review"` | **Review** | `Tasks/Review/*.md` — completed sessions awaiting audit. Full drain loop. |
| `"Rescue"` / `"rescue"` | **Rescue** | `Tasks/Working/` — rescue orphaned plans from crashed agents. Single pass, exits. |
| `"Audit"` / `"audit"` | **Audit** | No file triggers — runs Alignment Audit (default). Use `/audit align`, `/audit arch`, `/audit func`, `/audit feature --repo <name>`, or `/audit complete` for specific variants. |
| `"audit-func"` / `"Functional Audit"` / `"/audit func"` | **Audit (Functional)** | Run the Functional Audit — script-centric operational reliability survey across 6 domains |
| `"audit-complete"` / `"Complete Audit"` / `"/audit complete"` | **Audit (Complete)** | Run all 3 audits (Architectural + Functional concurrently, then Alignment) with cross-audit DependsOn |
| `"Cowork"` / `"cowork"` / `"cowork with me"` / `"let's cowork"` | **Cowork** | No file triggers — interactive pair-work. See `Skills/Archive/workflow-cowork-cowork.md`. |
| `"Bookkeeper"` / `"Bookkeeper"` | **Execute (Bookkeeper)** | No file triggers — runs the bookkeeping pipeline |
| `"RunFix Deploy"` / `"runfix deploy"` | **RunFix Deploy** | Runs `Skills/Docker/deploy.ps1` iteratively. See `runfix-deploy.md`. |
| `"RunFix <script>"` / `"runfix <script>"` | **RunFix (script mode)** | Runs any script iteratively. Goals from `runfix-<basename>.md`. Auto-assess if no goals file. |
| `"RunFix <command>"` / `"runfix <command>"` | **RunFix (command mode)** | Runs any command/workflow iteratively. Goals from `runfix-cmd-<command>.md`. |

> **RunFixFleet methodology**: For fleet-container troubleshooting without PowerShell, agents read `Skills/Archive/workflow-runfix-runfix-fleet-template.md` and self-loop within the current session. No command registration needed — include a single line in any handoff doc or prompt to invoke it. See `Skills/Orchestrator/Personas/Shared/tool-baseline.md § Script troubleshooting (RunFixFleet)`.
| `"Therapy"` / `"therapy"` / `"therapy mode"` | **Therapy** | No file triggers — interactive therapeutic support |

If a command explicitly names a mode (e.g., "Code", "Review"), go directly to that mode's workflow. Do not enter the `/work` Mode Selection flow. **Matching is case-insensitive** — `"review"`, `"Review"`, and `"REVIEW"` all trigger Review Mode.


## Fleet Command Words (Telegram/Signal)

When the user messages via Telegram (@IntersiteFRADbot) or Signal, the bot dispatches the message to ORCH. ORCH's job is prompt enrichment + task routing. The Fleet Command Words are the shortcuts the user can use:

| You say | ORCH action | VERI action |
|---------|-------------|-------------|
| "Plan X" or "I'd like you to plan" | Tag `workflow: planned`, route to VERI for plan writing | Write session plan to `Tasks/Code/`, return delivery |
| "Code X" or "Implement X" | Tag `workflow: planned` + `complexity: complex` (or `simple`), route to VERI | Dispatch to mcp_opencode for execution, return delivery |
| "Review X" or "Audit X" | Tag `workflow: review`, route to VERI | Dispatch to mcp_opencode for review, return feedback |
| "Rescue" | Tag `workflow: rescue`, route to VERI | Scan `Tasks/Working/`, reclaim stalled plans |
| "Cowork with me on X" | Tag `workflow: cowork`, route to VERI | Pair-work with the user |
| "Re-deploy" or "Redeploy" | Tag `workflow: redeploy`, route to VERI | Run RunFix Deploy on `Skills/Docker/deploy.ps1` iteratively |

## Two-Agent Dispatch Algorithm (VERI internal)

When VERI dispatches to `mcp_opencode`, it follows the Two-Agent Workflow:

1. **Controlling Agent** (in VERI) writes a self-contained task description.
2. The task is sent to **Coding Agent** (in mcp_opencode) via HTTP.
3. Coding Agent executes; returns result + diff + test output.
4. Controlling Agent reviews; if quality is insufficient, sends back for Pass 2.
5. Up to 3 passes (n=3). Iteration budget per `Skills/Orchestrator/Personas/Shared/protocols.md`.
6. Final result is delivered to ORCH.

## Complexity → Model Routing

| Complexity | Model | Use when |
|------------|-------|----------|
| `simple` | Flash-tier model (e.g., V4 Flash) | Single-file edits, lookups, file moves, well-scoped tasks |
| `complex` | Pro-tier model (e.g., V4 Pro) | Multi-file changes, architectural decisions, debugging, planning |

The tier-specific model is configured in `Infrastructure/ORCHESTRATOR/providers/<tier>-ORCHESTRATOR.json`. The user never specifies a model by name — they tag `complexity: complex` or `complexity: simple` and the role-appropriate model is selected.

## opencode workflow modes

The local CLI also has its own workflow modes (different from the persona modes above):

| Mode | SKILL.md location |
|------|-------------------|
| Bookkeeper | `Plugins/clock-lobster-books/account/workflow/SKILL.md` |
| Audit | `Skills/Auditor/SKILL.md` |
| Code | `Skills/Coder/SKILL.md` |
| Cowork | `Skills/Cowork/SKILL.md` |
| Plan | `Skills/Planner/SKILL.md` |
| Rescue | `Skills/Orchestrator/Rescue/SKILL.md` |
| Review | `Skills/Reviewer/SKILL.md` |
| RunFix | `Skills/Cowork/RunFix/runfix.md` |
| Secrets | `Skills/Auditor/Secrets/SKILL.md` |
| Therapy | `C:/Repos/Skills/Therapy/SKILL.md` |

Each opencode workflow has its own entry point and skill installation.

## Related skills

- `Skills/Orchestrator/Personas/Shared/protocols.md § Fleet Command Words` — fleet dispatch
- `AGENTS.md § Local CLI Mode-Taking Commands` — local CLI dispatch
- `Personas/VERI/agents.md § Two-Agent Workflow` — VERI's dispatch algorithm
- `../Create/Skill-Authoring/startup-sequence.md` — 10-step pattern




