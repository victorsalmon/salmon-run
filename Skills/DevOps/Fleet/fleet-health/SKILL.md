# Skill: Fleet Health

**Purpose**: Monitor and restore fleet health — health check commands, sentry monitoring reference, service recovery procedures, and a complete health endpoint table.

**Trigger**: "check fleet health", "is the fleet healthy?", "service X is stuck", "sentry detected a failure", "diagnose fleet"

---

## Health Check Commands

### Quick status — all services
```powershell
docker service ls
```
Shows every service with `REPLICAS` column: `N/N` = healthy, `0/N` = down, `N/M` (N<M) = transitioning.

### Per-service task detail
```powershell
docker service ps <service-name>
```
Lists individual tasks with `CurrentState` (e.g., `Running`, `Exited`, `Shutdown`) and `Error` column for failures.

### Container-level logs
```powershell
docker service logs <service-name>
```
Best for diagnosing runtime errors (`MODULE_NOT_FOUND`, import failures, crash loops). A service at `1/1` but crash-looping will show repeated `Exited` entries here.

### Health endpoint check
```powershell
# Internal overlay (run from a container or sentry)
curl -sf http://<service>:<port>/api/health

# Host port (if published)
curl -sf http://localhost:<host-port>/api/health
```
Every fleet container exposes `/api/health` returning HTTP 200 when healthy.

---

## Service Health Endpoint Table

| Service | Internal Port | Health Endpoint | Notes |
|---------|--------------|-----------------|-------|
| is-fleet | 21002 | `http://is-fleet:21002/api/health` | Orchestrator; do not restart unless necessary |
| is-api | 21003 | `http://is-api:21003/api/health` | Fleet API proxy |
| mcp_opencode | 21000 | `http://mcp_opencode:21000/api/health` | Primary opencode MCP server |
| mcp_aqe | 21004 | `http://mcp_aqe:21004/api/health` | AgenticQE quality tools |
| mcp_web (retired) | - | `-` | Retired 2026-08-22; web research via `/web-research`, rent tracking via `Skills/DevOps/Web/rent-tracking.md` |
| mcp_browserless | 3003 | `http://mcp_browserless:3003/pressure?token=$TOKEN` | Browser automation; health via `/pressure` (requires token) |
| mcp_docusign (retired) | — | `—` | Retired 2026-08-19 |
| is-bookkeeping (retired) | — | `—` | Retired 2026-08-21; functionality moved to `Skills/Bookkeeping/` and `Plugins/reconcile-account` |
| ops-funnel-proxy | 21009 | `http://ops-funnel-proxy:21009/api/health` | Funnel proxy |
| oc-orch-1 | 20100 | `http://<host>:20100/api/health` | ORCH gateway agent (host port) |
| oc-veri-* | 20200+ | `http://<host>:20200+/api/health` | VERI gateway agents (host port, up to 3) |
| oc-base-* | 20300+ | `http://<host>:20300+/api/health` | BASE gateway agents (host port, up to 3) |

---

## Fleet Monitoring Reference

Fleet is the fleet's autonomous health monitor. It runs in the `is-fleet` container with access to `/var/run/docker.sock`.

### What fleet checks (every 30 minutes)

| Check | Function | What It Detects |
|-------|----------|----------------|
| Stack health | `Test-FleetStackHealth` | Service replica counts vs desired state |
| Sidecar health | `Test-FleetSidecarHealth` | MCP sidecar containers running |
| Container health | `Test-FleetContainerHealth` | Docker health check status per container |
| Network connectivity | `Test-FleetNetworkConnectivity` | Overlay network reachability |
| Secret hydration | `Test-FleetSecretHydration` | Secrets properly injected |
| Secret resolution | `Test-FleetSecretResolution` | Secret names resolve to values |
| Swarm reality | `Test-FleetSwarmReality` | Actual state vs expected state |
| Volume integrity | `Test-FleetVolumeIntegrity` | Docker volumes exist and are mounted |
| Self-health | `Test-FleetSelfHealth` | Fleet itself is healthy |
| AQE topology | `Test-FleetAqeTopology` | AQE agent topology consistent |
| Code health | `Test-FleetCodeHealth` | Codebase-level health signals |
| Telegram polling | `Test-FleetTelegramPolling` | ORCH service Telegram polling is alive |

### How fleet remediates issues

When `Invoke-FleetHealthCheck` detects a problem, it calls `Invoke-FleetRemediation` which applies escalating interventions:

1. **Log the issue** — Record the failure for analysis
2. **Force-restart the service** — `docker service update --force <service>`
3. **Escalate** — If the same service fails on consecutive checks, write to the workflow events log

Fleet also starts `Start-FleetHealthListener` (HTTP endpoint on port 29999) for containers to POST health events.

### Reading sentry logs
```powershell
docker service logs is-fleet
```
Look for `[HEALTH]`, `[REMEDIATION]`, and `[WARN]` tags.

---

## Recovery Procedures

### Restart a single service
```powershell
docker service update --force <service-name>
```
Forces Swarm to restart all tasks of the service with new container IDs. Brief outage (<5s).

### Restart is-fleet (only when necessary)
is-fleet orchestrates auto-remediation. Only restart it when is-fleet itself is unhealthy or stuck.
```powershell
docker service update --force is-fleet
```

### Force-recreate all tasks (full fleet restart)
With only is-fleet in the stack, this restarts the fleet container:
```powershell
docker service ls --format "{{.Name}}" | ForEach-Object { docker service update --force $_ }
```
Causes brief fleet-wide outage. Use only when recovering from a systemic issue.

### Re-deploy the stack
```powershell
# Regenerate compose and re-deploy
.\Skills\Docker\1Deploy.ps1
# Or using deploy.ps1
.\Skills\Docker\deploy.ps1 -Phase FleetDeploy
```

### Clear stale containers
```powershell
# Remove all stopped containers
docker container prune -f
```

### Check fleet startup verification
```powershell
# Run the startup check manually
Invoke-FleetStartupCheck
```

---

## Fleet Module Functions

The `SalmonRun.Fleet` module provides PowerShell functions for fleet management:

| Function | Purpose |
|----------|---------|
| `Get-FleetServiceStatus` | Query all service replica counts |
| `Get-StackName` | Discover the current Docker Swarm stack name |
| `Restart-FleetService` | Restart a single service by name |
| `Wait-ServiceReady` | Poll until service reaches desired replica count |
| `Test-FleetReadiness` | Full fleet readiness check |
| `Resolve-ServiceName` | Map service name to its Docker service name |
| `Update-FleetServiceEnv` | Update environment variables on a running service |

---

## Red lines

- **Do not restart sentry unless necessary** — it orchestrates auto-remediation for the entire fleet.
- **Do not force-update all services at once** — causes brief fleet-wide outage. Use per-service restart when possible.
- **A service at 1/1 can still be unhealthy** — check `docker service logs` for runtime errors that don't cause container exit.
- **Compose-level health checks override Dockerfile HEALTHCHECK** in Swarm mode.
- **Port registry must match reality** — `Get-ServicePort` reads `Infrastructure/port-registry.json`. Mismatched ports cause silent health check failures.

---

## Cross-References

| Resource | Description |
|----------|-------------|
| `Skills/Cowork/RunFix/runfix-deploy.md` | Full redeploy workflow with automated health check (Phase 4.5) |
| `Skills/Docker/Modules/SalmonRun.Fleet/` | Fleet module source — health check and remediation logic |
| `Skills/Docker/Modules/SalmonRun.Fleet/` | Fleet module — service status, restart, readiness |
| `Skills/DevOps/Fleet/deploy-fleet/SKILL.md` | Deploy pipeline reference |
| `Infrastructure/port-registry.json` | Port registry for all services |
