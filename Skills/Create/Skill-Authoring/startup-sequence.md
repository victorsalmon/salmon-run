# Persona Startup Sequence — Canonical Reference

> **Audience**: Every persona (BASE) loads this file at session startup. The persona-specific `bootstrap.md` and `agents.md` files link here instead of duplicating the 10-step pattern.

Every ORCHESTRATOR persona follows the same 10-step startup. The pattern is read-then-acknowledge; some steps are required, some are persona-specific. Each persona's `bootstrap.md` documents its deltas.

## The 10-step standard pattern

| # | Step | File | Why |
|---|------|------|-----|
| 1 | **Identity** | `Personas/<ROLE>/soul.md` | Re-align with persona role and identity mandate. The `persona_anchor` in `Skills/skills.json` is the canonical path. |
| 2 | **Context** | `Skills/Orchestrator/Personas/Shared/user.md` | Owner's current business priorities, pronouns, preferences. |
| 3 | **Environment** | `Skills/Orchestrator/Personas/Shared/environment.md` | Workspace paths, inbox/outbox locations, configuration, AWS region. |
| 4 | **Boundaries** | `Skills/Orchestrator/Personas/Shared/boundaries.md` | Security and data residency rules. (Note: this file is the *security policy*, not the in-skill `## Red lines` section.) |
| 5 | **Protocols** | `Skills/Orchestrator/Personas/Shared/protocols.md` | The Three Passes Workflow (or solo loop), iteration budget, delegation standards. |
| 6 | **Fleet Topology** | `../DevOps/Fleet/fleet-topology.md` | Know your neighbors in the Docker Swarm stack. |
| 7 | **Projects** | `Skills/Orchestrator/Personas/Shared/projects.md` | Active client and project context. |
| 8 | **Git Repos** | `Skills/Orchestrator/Personas/Shared/git-repos.md` | Registry of shared workspace repositories. |
| 9 | **Tool Baseline** | `Skills/Orchestrator/Personas/Shared/tool-baseline.md` | Common tool constraints (model defaults, file ops, error handling, git discipline). |
| 10 | **Standing Directive** | (this is a reminder, not a file) | When asked about any tool, service, or capability, consult relevant documentation first. Do not guess. |

## Per-persona deltas

Each persona's `bootstrap.md` lists its deltas over the standard pattern:

- **BASE** — solo generalist. Uses `Write-NamespaceLog` for session logging. Runs `Discover-FleetCapabilities.ps1` at startup to build an ephemeral fleet capability map; references the map when selecting which container to call for a given task.

## Order matters

The numbered order is significant. Identity first (so the persona's role is locked in), then Context (owner state), then Environment (filesystem layout), then Boundaries (security rules), then Protocols (operating rules), then the rest. Loading protocols before boundaries would let the persona violate security rules before knowing they exist.

## What to do if a file is missing

A missing file in `Skills/Orchestrator/Personas/Shared/` is a critical configuration error. The persona cannot proceed without:

- `soul.md` (Identity) — the persona has no mandate.
- `user.md` (Context) — the persona doesn't know who it's serving.
- `boundaries.md` (Boundaries) — the persona doesn't know what it can't do.

Other files are recoverable — the persona can still operate, just with degraded context. Log a warning and continue.

## Related skills

- `Skills/ORCHESTRATOR/Personas/BASE/bootstrap.md` — per-persona deltas
- `Skills/OpenClaw/BASE/agents.md` — persona-specific deltas (link here, not duplicate)
- `Skills/Orchestrator/Personas/Shared/tool-baseline.md` — tool constraints
- `Skills/DevOps/Fleet/fleet-topology.md` — Docker Swarm neighbors
