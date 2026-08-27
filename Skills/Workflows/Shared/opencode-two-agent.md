# OpenCode Two-Agent Workflow

This document defines the Two-Agent coding workflow used by VERI (Sub-Orchestrator) to coordinate two CODE containers — a Controlling Agent and a Coding Agent — for complex multi-session software engineering projects.

> **About this document**: Core primitives → [`Skills/Create/Skill-Authoring/workflow-primitives.md`](Skills/Create/Skill-Authoring/workflow-primitives.md). This file covers role wiring, 4-phase flow, sentry integration, and Alignment Audit.

## Architecture

```
ORCH dispatch (code/file tasks)
    │
    ▼
VERI (Sub-Orchestrator)
    │
    ├──► Planner (session planning)
    ├──► Coder (implementation + quality validation)
    ├──► Reviewer (code audit)
    └──► Agentic QE (MCP tools — invoked by Coder)
```

Communication is via the CODE Server API through HTTP (`http://mcp_opencode:21001`). VERI creates sessions for each task via `POST /session` and dispatches via `POST /session/:id/prompt_async`. Fallback is filesystem-based through the shared workspace repo. VERI prevents git conflicts by branch-per-task isolation and independence analysis (see Phase 2a).

### Connascence

Files sharing the same date+name prefix (e.g. `2026.05.05proj-*.md`) are connascent — locked as a unit per [`Skills/Create/Skill-Authoring/workflow-primitives.md § Connascence`](Skills/Create/Skill-Authoring/workflow-primitives.md#connascence).

## Role Definitions

Each CODE container role references its workflow definition as follows:

| Role | Workflow Source | Model | Purpose |
|------|----------------|-------|---------|
| **Planner** | [`Skills/Planner/SKILL.md`](../../Planner/SKILL.md) (mode overview) + [`Skills/Planner/workflow.md`](../../Planner/workflow.md) (workflow) | Flash Max (default) / V4 Pro (escalation) | Writes session plans, owns brainstorming |
| **Coder** | [`Skills/Coder/SKILL.md`](Skills/Coder/SKILL.md) | V4 Flash (effort: max) | Implements code changes per session plans |
| **Reviewer** | [`Skills/Reviewer/SKILL.md`](Skills/Reviewer/SKILL.md) | Flash Max (default) / V4 Pro (escalation) | Audits results, tracks progress |
| **Agentic QE** | MCP tools (`mcp__agentic-qe__*`) available in CODING/CONTROLLING containers | V4 Flash (effort: max) | Autonomous quality validation via PACT framework |

Refer to each source for full duty lists, constraints, and configuration.

## Task Folder Structure

```
Tasks/
  Tasks/Code/                       ← Session plans & feedback files (Controlling Agent writes here)
  Tasks/Working/                    ← Coder moves plans here + prepends Lock Header
  Tasks/Review/                     ← Coder moves completed plans here; Reviewer reads from here
  Tasks/Complete/                   ← Reviewer moves audited plans here (loose files)
  Tasks/Complete/<namespace>/             ← Grouped subfolder once ALL sessions are done.
                                 <namespace> is computed by Get-FileNamespace
                                 (Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1) —
                                 the full segment between the date prefix and the
                                 iteration number, e.g. csbk-fe-dash. Never abbreviated.
                                 Loose files in Complete/ = partially completed task
                                 Subfolder in Complete/ = fully completed task
  Tasks/Manual/                     ← Human-action instructions (never auto-processed)
```

## Full 4-Phase Workflow

### Phase 1 — Planning Step (Planner)

VERI dispatches the **Planner** (see `Skills/Planner/SKILL.md` and `Skills/Planner/workflow.md`) with the task description from ORCH.

1. Planner analyzes the task requirements.
2. Creates `Tasks/Code/<date>-<namespace>-<iteration>-<description>.md` with:
   - Overview of the task scope
   - Numbered task list, each with: file path(s), specific changes, acceptance criteria
   - `%_complete: 0%` metadata
3. Session plans must be sized for a single V4 Flash run — typically 2-5 tasks per session. **Sessions must be small enough for DeepSeek V4 Flash Max to complete without exceeding 250K tokens of context (the Flash Max exit-context target). See `session-plan-format.md` ┬º Token Estimation Heuristic.**
4. If any task item requires human action (AWS console operations, external service signups, physical device configuration), create a file in `Tasks/Manual/` with naming format `$date-$topic.md`. Each manual task file must include originating context, date created, detailed step-by-step instructions, expected outcome, and follow-up actions. Log the deferral under `## Deferred Tasks` in the session plan.
5. Returns control to VERI with the plan path.

### Phase 2 — Implementation + Quality Validation (VERI + Coding Agents)

VERI manages implementation through 4 sub-phases: independence analysis, parallel batch dispatch, collect-and-merge, and push.

#### Phase 2a — Independence analysis (VERI)

1. Read session plan, extract `**Files:**` from each task.
2. Build file-to-task conflict map — tasks with no overlapping files are parallel-safe.
3. Group non-overlapping tasks into parallel batches.
4. Cap: `CODE_SERVER_MAX_CONCURRENT_SESSIONS` (default 3).

#### Phase 2b — Batch dispatch (VERI)

For each batch:
1. Create N sessions via `POST /session` to `http://mcp_opencode:21001`.
2. Branch per task using the helper script: `Infrastructure/git-task-branch.sh start <name> <session-id>`.
3. Dispatch each via `POST /session/:id/prompt_async`.
4. All fire in parallel (async dispatch).

#### Phase 2c — Collect + merge (VERI)

1. Poll `GET /session/:id/message` for each session.
2. Collect diffs via `GET /session/:id/diff`.
3. Merge branches: `git merge --ff-only task/<name>`.
4. If merge fails, flag as non-independent, re-run serially.

#### Phase 2d — Push (VERI)

1. `git push`.
2. Confirm all sessions are in `Tasks/Review/` with Lock Headers set to `Status: released` and `Progress: 100%`.
3. If deferred tasks remain, the Coding Agent notes them below the Lock bar (see Lock Header section).
4. VERI signals completion.

**Quality Validation (VERI-owned)**: After the Coding Agent completes each session, VERI runs `mcp__agentic-qe__quality_assess` on changed files using MCP tools available in the VERI container. VERI fixes any CONDITIONAL/FAIL findings, re-runs until PASS, then writes the PACT scorecard to `Tasks/Review/<session>-pact-assessment.md`. The Coding Agent no longer runs AQE — this is VERI's responsibility.

### Phase 3 — Code Review Step (Reviewer)

VERI dispatches the **Reviewer** (see `Skills/Workflows/Review/workflow.md`) for audit.

1. Reads ALL session plans and PACT scorecards in `Tasks/Review/`.
2. For each plan:
   - **Reads PACT scorecard** — looks for `<session>-pact-assessment.md` alongside each session plan, incorporates findings into the audit
   - Verifies listed outputs exist on disk.
   - Audits code changes against acceptance criteria.
    - Runs Pester tests (git-aware per `Skills/Create/Skill-Authoring/Skills/Create/Skill-Authoring/workflow-primitives.md § Complete CC`) — all must pass. If a test fails due to a script error, **check the log files first** (`Tasks/Logs/`, test output, stderr) to diagnose the root cause before auditing the code. If no module code changed, skip.
3. Assesses **% complete** of the overall task:
   - Counts accepted plan items vs. total planned items.
   - Stores the % in feedback file as `%_complete: <N>%`.
4. Compares to the previous review's % complete (from prior feedback file, if any).

#### 3-Strike Failure Mechanism

- **3 consecutive failed turns** (no progress in 3 straight reviews) triggers task failure.
- Progress resets the fail counter to 0.
- On task failure, the Controlling Agent writes a task failure summary including:
  - Current % complete
  - What specific items are stuck and why
  - Recommendations for how future failures could be minimized or prevented
- VERI returns the failure to ORCH with the explanation.

5. Moves audited plans from `Tasks/Working/` to `Tasks/Complete/` (as loose files). When ALL session files for a task project are present in `Tasks/Complete/`, group them into a task-named subfolder.
6. Writes `Tasks/Code/<date>-feedback.md` with:
   - Audit table: session → status (COMPLETED / PARTIALLY COMPLETED / NOT COMPLETED)
   - Numbered issues with detailed "Tasks to complete" lists (self-contained)
   - Dependency order for remaining issues
   - Current % complete and fail count
7. Signals VERI.

### Phase 4 — Final Review (VERI)

1. When Controlling Agent reports 100% complete with no remaining issues:
   - VERI performs final review: reads all deliverables, verifies quality.
   - VERI runs Pester one final time (git-aware per `Skills/Create/Skill-Authoring/Skills/Create/Skill-Authoring/workflow-primitives.md § Complete CC`).
2. If all passes:
   - VERI confirms all files are grouped in `Tasks/Complete/<date>-<namespace>/` (Reviewer should have already completed the grouping during Phase 3).
   - VERI does final polish if needed.
   - VERI delivers final output to ORCH.
3. If VERI finds remaining issues during final review:
   - VERI writes a brief feedback note.
   - Re-dispatches Coding Agent (one final loop).

> Session plan format is defined in [`Skills/Workflows/Shared/session-plan-format.md`](../Shared/session-plan-format.md) (format spec) and the mode overview is at [`Skills/Planner/SKILL.md`](../../Planner/SKILL.md).

## Complete CC (Coding Agent)
After every implementation session, the Coding Agent runs the [Complete CC](Skills/Create/Skill-Authoring/workflow-primitives.md#complete-cc-shared-snippets) per `Skills/Create/Skill-Authoring/workflow-primitives.md` (10 steps, canonical).
**In orchestrated mode** (dispatch via LocalOrchestrator or VERI):
- Step 8 (verify clean tree) and Step 11 (Drain Queue) are the **orchestrator's responsibility** — the Coding Agent subprocess skips them
- All other steps run identically to interactive mode

The Coding Agent in interactive mode runs the full 10 steps including Step 8 and Step 11. Never: update git config, skip hooks, force push to main, rebase/amend pushed commits. Never expose or log secrets.

## VERI's Git Conflict Prevention

Branch per task (`git checkout -b task/<name>-<session>`). Clean tree before dispatch. Never parallelize across phases — only within the Coding phase. See [`Skills/Create/Skill-Authoring/workflow-primitives.md § Multi-agent coexistence`](Skills/Create/Skill-Authoring/workflow-primitives.md#multi-agent-coexistence) for git discipline.

## Sentry-Automated Agent Spawning

The sentry container monitors task folders and **dispatches tasks** to the CODE server. It manages the daily event log and dispatches tasks with capacity awareness.

| Function | Detail |
| :--- | :--- |
| **Watch `Tasks/Code/`** | Detects new `.md` plans → dispatches via CODE Server API (`POST /session` + `POST /session/:id/prompt_async`) |
| **Watch `Tasks/Review/`** | Detects completed plans → dispatches a Reviewer via CODE Server API |
| **Server API dispatch** | In server mode (`INSTALL_CODE_SERVER_MODE=true`), sends tasks as HTTP sessions to `http://mcp_opencode:21001` instead of file-based trigger drops |
| **Capacity awareness** | Server mode handles N concurrent sessions — no container spawning needed for parallelism |
| **Stall detection** | Monitors `Tasks/Working/` Lock Header timestamps — if untouched for >5 min, flags as `[STALLED]` and logs the event |
| **Daily event log** | Maintains `/workspace/logs/YYYY-MM-DD.log` with structured entries. Exposes `POST http://sentry:29999/log` endpoint for any container on `service_net` to write log entries. |
| **Heartbeat** | Writes a log entry each poll cycle showing active sessions |
| **Git sync** | Runs `git pull` each cycle to pick up remote changes |
| **Resource limit** | 1G memory, Docker socket mounted |

The sentry's task dispatch loop runs as a background job within the sentry container. In server mode, it uses the HTTP API directly. In legacy worker mode, Coders and Reviewers handle file movement themselves.

> **See also**: [Lock Header](Skills/Create/Skill-Authoring/workflow-primitives.md#lock-header-chain-of-possession) · [Manual Dispatch](Skills/Create/Skill-Authoring/workflow-primitives.md#manual-dispatch-signals-legacy-flow) · [Completion Signal](Skills/Create/Skill-Authoring/workflow-primitives.md#completion-signal)

## Multi-Session Orchestration (Alignment Audit Pattern)

> **See also**: Auditor workflow → [`Skills/Workflows/Audit/workflow.md`](../Audit/workflow.md), audit completion → [`alignment-audit.md#completion-checklist`](../Audit/alignment-audit.md#completion-checklist)

The Auditor role (see `Skills/Auditor/alignment-audit.md`) surveys the codebase for drift and produces multiple session plans for Coders to implement. Unlike the Planner, the Auditor has a fixed survey methodology and produces plans across pre-defined domains.

### How It Works

```
User: "Audit"
    │
    ▼ Auditor runs survey batch (3-4 domains)
    │   Write-AlignmentAuditLog entries per finding
    │
    ▼ Writes session plan(s) to Tasks/ root
    │   Tasks/<date>-alignment-<domain><N>.md  (**Status**: ready)
    │
    ▼ Compacts memory, continues next batch
    │
    ▼ All batches complete → close-out log → exit
```

After the Auditor exits, Coders scan `Tasks/Code/`, discover the alignment plans (moved from `Tasks/` root to `Tasks/Code/` by the orchestrator), lock them, and implement them through the standard Coder → Reviewer → Complete workflow.

### Key Differences From Standard Plans

| Aspect | Planner-Created Plan | Auditor-Created Plan |
|--------|---------------------|---------------------|
| **Origin** | Written by Planner from user request | Written by Auditor during alignment survey |
| **Namespace** | Any descriptive name | Prefixed with `alignment-<domain>` |
| **Parent** | None | Optional `**Parent**: <date>-alignment-audit.md` field |
| **Purpose** | Feature/refactor/bugfix | Drift remediation (tests, docs, agent configs, etc.) |
| **Lifecycle** | Standard Coder pickup | Standard Coder pickup (same as any plan) |

The Auditor does not self-implement — all alignment plans flow through the normal Coder pipeline.
```
