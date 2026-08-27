# Fleet Topology — Canonical Reference

> **Audience**: Loaded at session startup for fleet context. Updated 2026-08-25 for the MCP/Hermes/openclaw and schedule-poller retirement.

The ORCHESTRATOR fleet runs as a Docker Swarm stack with **one container** (`is-fleet`) plus a **host-side local orchestrator/watchdog** (`Invoke-Orchestrate.ps1`). All MCP sidecars, the openclaw agent layer, Hermes, Bookkeeper, Marketer, the funnel proxy, and the schedule-poller service were retired 2026-08-21/2026-08-25. Code/research/bookkeeping/marketing/signing execution moved to the host via the local orchestrator + cross-harness skills.

## Service inventory

| Service | Name | Role | Network | Notes |
|---------|------|------|---------|-------|
| `is-fleet` | — | Docker operator + fleet health checks + infrastructure remediation | service_net + management_net | Sole Docker-socket holder. Health checks: stack health, network connectivity, self-health. Internal port 21002, host port 29999. |
| Host orchestrator | — | Local agent process lifecycle + queue monitoring + stall detection | host (not a container) | `Invoke-Orchestrate.ps1` polls `Tasks/Code/` and `Tasks/Review/`, spawns opencode processes, monitors heartbeats, cleans stale agents, re-launches after crashes. Detached watchdog mode via `-DetachWatchdog`. |

### Retired services (2026-08-21 and 2026-08-25)

The following services were removed from the runtime. Their latest images are retained locally for future experimentation (see `docs/Reference/retained-images.md`).

| Service | Replacement |
|---------|-------------|
| `mcp_opencode` | Host orchestrator spawns opencode processes per plan file |
| `oc-base` (Maestro) | Host orchestrator + cross-harness skills |
| `mcp_web` | `/web-research` cross-harness skill |
| `mcp_aqe` | `/aqe` cross-harness skill (retired earlier 2026-08-21) |
| `mcp_browserless` | `/browser-web-ops` cross-harness skill |
| `mcp_docusign` | Self-hosted `@clocklobster/signing-*` modules (retired earlier) |
| `is-marketer` | `/marketing-outreach` cross-harness skill |
| `is-bookkeeping` | `reconcile-account` Devin plugin (retired earlier) |
| `is-hermes` | Image retained as `openclaw-retained:latest` (no active replacement) |
| `ops-funnel-proxy` | No public HTTPS ingress (cloudflared/tailscale funnel removed) |
| `schedule-poller` | Host orchestrator + Windows Task Scheduler (retired 2026-08-25) |

## Credential & Secret Mounts

Docker Swarm secrets are mounted per service. See `docker-manifest.json` for the full manifest.

| Service | Keys mounted | Notes |
|---------|--------------|-------|
| `is-fleet` | AWS id/secret, GitHub token, FLEET_API_TOKEN_FLEET, FLEET_API_TOKEN_MONITOR | Docker socket mounted for fleet operations. Sole Docker operator. |


## Filesystem Bind Mounts

| Service | Host path | Container path | Purpose |
|---------|-----------|----------------|---------|
| `is-fleet` | `/var/run/docker.sock` | `/var/run/docker.sock` | Docker daemon socket for fleet operations. |
| `is-fleet` | `~/.ORCHESTRATOR` | `/home/node/.ORCHESTRATOR` | User ORCHESTRATOR config. |
| `is-fleet` | `<repo-root>/Tasks/Logs` | `/home/node/.ORCHESTRATOR/workspace/reports` | Fleet logs and reports. |
| `is-fleet` | `<repo-root>/install.json` | `/home/node/app/install.json` | Install manifest. |
| `is-fleet` | `<repo-root>/Tasks/Schedule` | `/workspace/repo/Tasks/Schedule` | Schedule file access. |
| `is-fleet` | `<repo-root>/Tasks/Code` | `/workspace/repo/Tasks/Code` | Code task queue access. |
| `is-fleet` | `<repo-root>/Tasks` | `/workspace/repo/Tasks:rw` | Task queue read/write for host orchestrator polling. |
| `is-fleet` | `<repo-root>/Skills` | `/workspace/repo/Skills:rw` | Skills access for schedule-driven operations. |
| `is-fleet` | `~/.ORCHESTRATOR` | `/home/node/.ORCHESTRATOR` | User ORCHESTRATOR config. |
| `is-fleet` | `<repo-root>/Tasks/Logs` | `/home/node/.ORCHESTRATOR/workspace/reports` | Log access. |
| `is-fleet` | `<repo-root>/install.json` | `/home/node/app/install.json` | Install manifest. |

## Communication Topology

```
Schedule JSON → Windows Task Scheduler / host orchestrator (poll) → plan file in Tasks/Code/ → host orchestrator (poll) → opencode process → git push → Tasks/Review/ → host orchestrator (review) → merge
```

The host orchestrator writes plan files from schedule JSON and consumes them. is-fleet monitors its own health and the host orchestrator process. The host watchdog monitors the orchestrator process itself.

## Network Segmentation

| Network | Services | Purpose |
|---------|----------|---------|
| `service_net` | is-fleet | General-purpose overlay |
| `management_net` | is-fleet | Fleet management network |

Overlay networks are trusted — no mTLS or network-level ACLs. Cross-network access is blocked by default.

## Self-Healing Layers

| Layer | Owner | What it monitors | Remediation |
|-------|-------|------------------|-------------|

| is-fleet container | Docker Swarm | `restart_policy: condition=any` | Swarm auto-restarts |
| Host orchestrator | Host watchdog | PID/heartbeat files, queue progress | Re-launches orchestrator, cleans stale agents |
| Plan files | Host orchestrator health check | Stuck Working/ files, Failed/ accumulation | Rescues stale plans back to Code/Review queue |
