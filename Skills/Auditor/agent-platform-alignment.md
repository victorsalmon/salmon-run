---
name: oc-agent-platform-alignment
description: Lessons learned about ORCHESTRATOR platform usage by fleet agents — path conventions, terminology, mount architecture, and recurring failure patterns. Use when auditing agent persona files, compose config, or workflow docs for platform-alignment drift.
type: methodology
flavor: ORCHESTRATOR
loaded_by: any opencode CLI session
container: opencode
---

# OC Agent-Platform Alignment — Audit Reference

**Type**: methodology
**Flavor**: ORCHESTRATOR
**Loaded by**: any opencode CLI session, Audit mode

## Purpose

Capture institutional lessons about how ORCHESTRATOR agents use the platform: filesystem conventions, mount architecture, naming standards, and patterns that tend to break or drift. The Audit mode uses this skill as a reference when scanning for alignment issues.

## When to Load

- During an **Alignment Audit** (domain 6: Skills & Workflow Artifacts, or domain 2: Deep Code Analysis)
- When auditing **persona files** (agents.md, system-prompt.md, tools.md, soul.md, etc.) for path correctness
- When reviewing **compose configuration** or **deploy modules** for mount consistency
- When checking for **terminology drift** across the codebase
- After any session that uncovered a platform-level gotcha — add the lesson here

## How to Use

1. Load this skill during any audit that touches agent configuration or platform infrastructure
2. Check each lesson category below against the target files
3. If a new pattern is discovered, add it under the appropriate section or create a new category
4. Update the Changelog with a one-line entry

## Lessons

### Path Conventions

| Lesson | Detail |
|--------|--------|
| **Absolute paths in persona files** | VERI/ORCH persona files loaded into containers must use absolute paths (`/workspace/Fleet Tasks/Code/`), not relative (`Tasks/Code/`). Inside the container, the working directory is the workspace volume's repo clone (e.g., `/workspace/intersite-orchestrator`). Relative `Tasks/` resolves to the workspace volume, not the bind mount. |
| **Bind mount path** | The Fleet Tasks bind mount (`New-FleetCompose.ps1:167`) maps `<repo-root>/Tasks` → `/workspace/Fleet Tasks`. This gives ORCH/VERI a live view of the host's `Tasks/` directory, bypassing the workspace volume's potentially stale git clone. |
| **Workspace volume path** | The `interclaw_workspace` volume mounts at `/workspace` and contains git-cloned repos. CODE containers write results here. These two paths (`/workspace/<repo>/Tasks` vs `/workspace/Fleet Tasks`) are **different filesystems** inside the container and can diverge. |
| **Sentry mount path** | Sentry mounts `interclaw_workspace` at `/workspace/repo` (subpath), while mcp_opencode mounts it at `/workspace` (root). Both use the same underlying volume but see different directory structures. See `New-FleetCompose.ps1:246-252`. |
| **ORCH-only paths** | ORCH persona files had no `Tasks/` path references at all — clean. Always check ORCH as the baseline for correct path hygiene. |

### Terminology & Naming

| Lesson | Detail |
|--------|--------|
| **"CODE containers" is stale** | Replaced by "opencode containers" or "mcp_opencode container". The old term persists in persona files, comments, and docs. Audit grep pattern: `\bCODE\b` (case-sensitive, word boundary) — should return zero matches in persona files. |
| **Commit prefix convention** | `[CODE-<Id>]` is stale. Use `[OC-<Id>]` for opencode container commit messages. Documented in `opencode-acp.md`. |
| **Service naming** | The single mcp_opencode container is the only opencode serve instance. References to multiple `code-<ID>` instances in docs may be stale. |
| **Persona file naming** | Persona files live at `Skills/ORCHESTRATOR/Personas/<Role>/`. Files are case-insensitive on the host but lowercase inside the container (seeded via `Initialize-AgentVolumes.ps1` line 211). |

### Mount Architecture

| Lesson | Detail |
|--------|--------|
| **Who gets the bind mount** | Only ORCH and VERI have `<repo-root>/Tasks:/workspace/Fleet Tasks`. CODE containers (mcp_opencode) do NOT get this mount — they write to the workspace volume. |
| **CODE results visibility** | CODE container results come back through Server API session polling (`GET /session/:id/message`), NOT through filesystem watching. The bind mount Review/ watching catches results that arrive via git push/pull or host-side operations. |
| **Real-time vs git** | The bind mount gives real-time host filesystem access. The workspace volume is a git clone updated only during deploy. If a file needs to be visible to VERI immediately, it must go through the bind mount path. |
| **Outbox directory** | ORCH Outbox bind mount at `<repo-root>/workspace/ORCH Outbox:/workspace/ORCH Outbox`. Only ORCH and VERI have this mount. |

### Recurring Failure Patterns

| Pattern | Root Cause | Prevention |
|---------|------------|------------|
| Persona files use relative `Tasks/` paths | Authors assume working directory is repo root with direct `Tasks/` access. Inside containers, working directory is the workspace volume's repo clone. | Use absolute `/workspace/Fleet Tasks/` for all ORCH/VERI file operations in persona files. |
| Stale "CODE containers" terminology persists | The rename from CODE containers to mcp_opencode happened in the deployment code but persona files were not updated. | Case-sensitive grep for `\bCODE\b` in persona files. Commit prefix `[CODE-<Id>]` should be `[OC-<Id>]`. |
| Workspace volume vs bind mount confusion | Two different mounts serve the same logical `Tasks/` directory. Agents may write to one and read from the other, missing results. | Understand which mount each agent role has. VERI reads from bind mount. CODE writes to workspace volume. Results return via API, not filesystem. |
| Persona file edits not deployed | Persona files are static copies seeded into `agent_config_*` Docker volumes at deploy time. Editing them on the host does not update running containers. | After persona file changes, run `Invoke-AgentReseed` or redeploy the stack. |
| Schedule agent writes result to `error` field | The `error` field was the only place to store output; no `result` field existed in the schedule schema. | Use `result` for success (`"plan completed"`), `error` only for actual failures. The plan template in `Start-TempoSchedulePoller.ps1:Write-SchedulePlan` now instructs agents to set `result` and clear `error`. |

### Operational Knowledge

| Topic | Detail |
|-------|--------|
| **Reseeding persona files** | After editing persona files on the host, run `Invoke-AgentReseed` to push them into running containers without a full redeploy. The module bootstrap sequence: add `Skills/Docker/Modules` to `PSModulePath`, then `Import-Module SalmonRun.Paths`, `Import-Module SalmonRun.ModuleLoader`, `Import-ORCHESTRATORModule Core`, `Import-ORCHESTRATORModule Diagnostics`, `Import-ORCHESTRATORModule Config`, `Import-ORCHESTRATORModule Identity`, `Import-ORCHESTRATORModule DeployState`, `Import-ORCHESTRATORModule Deploy`. Then call `Invoke-AgentReseed -Roles @("VERI") -Restart:$true -Force`. The `-Restart` parameter takes a boolean (`$true`/`$false`), not a switch. |
| **Module dependency chain** | `SalmonRun.Deploy` requires `SalmonRun.Paths → ModuleLoader → Core → Diagnostics → Config → Identity → DeployState` to load successfully. Missing any link causes silent import failure. |
| **Schedule file lifecycle** | Tempo's `Start-TempoSchedulePoller` scans `Tasks/Schedule/*.json` every 60s. The `repeat` field supports cron expressions (5-field, e.g. `"0 0 1 * *"`). Pending schedules are triggered (status → `"triggered"`, dispatched). After completion, cron schedules are auto-re-armed by the poller (status → `"pending"` with next `scheduled_at`). Non-cron completed schedules are purged after 48h. Schedules stuck in `"triggered"` > 2h are retried by the watchdog. The local poller (`Start-LocalSchedulePoller.ps1`) is deprecated — Tempo is the sole scheduler. |

### Audit Checklist

When auditing persona files for platform alignment:

- [ ] All `Tasks/` paths use absolute `/workspace/Fleet Tasks/` prefix (for ORCH/VERI)
- [ ] Zero matches for `\bCODE\b` (case-sensitive) — should be "opencode" or "mcp_opencode"
- [ ] No hardcoded paths to legacy worker-inbox, verifier-inbox, orchestrator-outbox
- [ ] Commit prefix conventions use `[OC-<Id>]` not `[CODE-<Id>]`
- [ ] Mount paths match `New-FleetCompose.ps1` and `fleet-topology.md`
- [ ] Persona files describing CODE container actions use relative `Tasks/` (correct — CODE containers work in workspace volume)

## Cross-References

- `Skills/Auditor/alignment-audit.md` — Alignment Audit master workflow (domain 6: Skills & Workflow Artifacts)
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — Agent workflow primitives, lock headers, connascence
- `Skills/DevOps/Fleet/fleet-topology.md` — Canonical fleet service inventory and mount registry
- `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1` — Compose generation (mount definitions)
- `Skills/Docker/Modules/SalmonRun.Deploy/Public/Initialize-AgentVolumes.ps1` — Volume seeding and workspace clone
- `Orchestrator/Orchestration/Personas/VERI/` — VERI persona files (primary audit target)
- `Orchestrator/Orchestration/Personas/ORCH/` — ORCH persona files (secondary audit target)
- `Skills/Orchestrator/Scheduler/SKILL.md` — Schedule schema with `result`/`error` field semantics
- `Orchestrator/Modules/SalmonRun.Tempo/Public/Start-TempoSchedulePoller.ps1` — Schedule poller, plan template, stale watchdog

## Changelog

- 2026-06-20: Initial creation — path conventions, terminology, mount architecture, recurring failure patterns
- 2026-06-20: Added schedule result/error field pattern to Recurring Failure Patterns
- 2026-06-20: Added Operational Knowledge section (module bootstrap, reseed, schedule lifecycle)
