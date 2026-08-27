# Skill: Deploy Fleet

**Purpose**: Guide agents through the `deploy.ps1` fleet deployment pipeline — phase reference, re-run guidance, pre-flight checklist, post-deploy verification, and common failure modes.

**Trigger**: "deploy the fleet", "run deploy.ps1", "deployment failed at phase X", "re-deploy", "redeploy"

**Prerequisites**: PowerShell 7+, AWS SSO-capable CLI (`aws sso login --profile intersite`), Docker Desktop running, write access to `Skills/Docker/` and task files.

---

## Phase Reference

| # | Phase Name | What It Does | Run Solo | Typical Duration | Common Failure Mode |
|---|-----------|-------------|----------|-----------------|-------------------|
| 0 | HostReadiness | Checks hardware, OS, virtualization, Hyper-V, WSL2 | `-Phase HostReadiness` | 10s | Hyper-V not enabled; WSL2 missing |
| 1 | Prerequisites | Verifies PowerShell 7, Git, winget packages | `-Phase Prerequisites` | 15s | Package not installed via winget |
| 2 | Identity | Resolves agent identity (names, sovereignty tier, coding keys) | `-Phase Identity` | 30s | Missing owner config in `~/.ORCHESTRATOR/` |
| 3 | FleetToggles | Sets feature flags (Tailscale, Sentry, opencode, Docusign, etc.) | `-Phase FleetToggles` | 10s | Invalid toggle value in install.json |
| — | ExportInstallJson | Saves current install.json as checkpoint for resume | `-Phase ExportInstallJson` | 5s | Write permissions on install.json |
| 4 | AwsSso | Initiates AWS SSO login, captures token | `-Phase AwsSso` | 30–120s | SSO browser timeout; profile not configured |
| 5 | Tailscale | Installs/configures Tailscale (Windows native app, subnet router) | `-Phase Tailscale` | 60s | Tailscale auth key expired |
| 6 | BitLocker | Checks BitLocker encryption status (recoverable) | `-Phase BitLocker` | 10s | BitLocker not enabled (recoverable) |
| 7 | Docker | Background job: Docker Desktop install + Swarm init | `-Phase Docker` | 5–15 min | Docker Desktop not installed; Swarm init failure |
| — | JOIN | Wait for Docker background job to complete | — | Varies | Docker job hung or failed |
| 8 | ResourcePreflight | Measures Docker resources (CPU, RAM, disk) vs fleet budget | `-Phase ResourcePreflight` | 10s | Insufficient resources for fleet |
| 8.5 | AwsPreflight | Validates AWS connectivity, checks secrets region | `-Phase AwsPreflight` | 15s | AWS CLI not authenticated; region unreachable |
| 9a | AgentProvisioning | Creates per-agent IAM users + Bedrock provisioning (parallel) | `-Phase AgentProvisioning` | 60s | IAM role limits exceeded |
| 9b | OrchestratorInfrastructure | Sets up orchestration IAM roles, sentry, rekognition fallback | `-Phase OrchestratorInfrastructure` | 30s | Role already exists with conflicting policy |
| 9c | CredentialIsolationTests | Tests that each agent's credentials are properly isolated | `-Phase CredentialIsolationTests` | 20s | Cross-credential access detected |
| 10 | DockerSecrets | Hydrates AWS SM secrets → Docker Swarm secrets | `-Phase DockerSecrets` | 30s | AWS SM secret missing or malformed |
| 11 | FleetDeploy | Generates compose YAML, `docker stack deploy`, health verification | `-Phase FleetDeploy` | 180s | Port conflict; image not built |
| 12 | ConfigSave | Persists deployment config to disk | `-Phase ConfigSave` | 10s | Write permissions |
| 13 | IdentityConfig | Delegates to config.ps1 (Telegram pairing, placeholders) | `-Phase IdentityConfig` | 120s | Telegram bot unreachable |
| 14 | Cleanup | Cleans temporary files, orphaned secrets (recoverable) | `-Phase Cleanup` | 15s | File in use by another process |

### Phase execution model

Each phase is wrapped in `Invoke-ConditionalPhase`, which checks `-Phase` parameter. When `-Phase ''` (default), all phases run. When `-Phase PhaseName`, only that phase runs. The `TagOnly` switch limits phases to ConfigSave, IdentityConfig, and Cleanup.

---

## Re-run Guidance

### Run all phases (fresh deployment)
```powershell
.\Skills\Docker\deploy.ps1
```

### Run from a specific phase (skip preceding phases)
```powershell
.\Skills\Docker\deploy.ps1 -Phase FleetDeploy
```
Only `FleetDeploy` runs — all earlier phases are skipped. Useful after fixing a late-phase failure.

### Dry-run (what-if mode)
```powershell
.\Skills\Docker\deploy.ps1 -WhatIf
```
Logs all actions without executing. Combined with `-Phase` to preview a single phase.

### Tag-only mode (config/cleanup only)
```powershell
.\Skills\Docker\deploy.ps1 -TagOnly
```
Only ConfigSave, IdentityConfig, and Cleanup run. Skips provisioning and deployment.

### Recovery after failure
1. Diagnose the failure (check `Tasks/Logs/setup-*.log` and `setup-warnings-*.log`).
2. Fix the root cause in the source code (not in runtime state).
3. Re-run from the failing phase: `.\deploy.ps1 -Phase <PhaseName>`.
4. If checkpoint resume is active (`$env:ORCHESTRATOR_RUN_ID` is set and install.json has fleet agents), agent configs are restored automatically — no need to re-run identity phases.

### Full redeploy
For a complete redeploy (e.g., after code changes to modules or compose):
```powershell
.\Skills\Docker\deploy.ps1 -DroneMode
```
DroneMode skips interactive prompts for a headless rebuild.

---

## Pre-flight Checklist

Before running `deploy.ps1`, verify:

- [ ] **AWS SSO session active**: Run `aws sso login --profile intersite` if not already logged in.
- [ ] **Docker Desktop running**: `docker info` returns successfully.
- [ ] **Git status clean**: `git status --porcelain` shows no modified or untracked files.
- [ ] **PowerShell 7+**: `$PSVersionTable.PSVersion.Major -ge 7`.
- [ ] **Owner config exists**: `~/.ORCHESTRATOR/owner-config.json` has all placeholders filled (created by `config.ps1`).
- [ ] **Not running on a container**: deploy.ps1 is a host-side script — it sets up the host environment and should never run inside a Docker container.
- [ ] **Sufficient disk space**: At least 20GB free for Docker images and volumes.
- [ ] **VMware/Hyper-V enabled**: Required for Docker Desktop WSL2 backend.

---

## Post-deploy Verification

After `deploy.ps1` completes successfully:

- [ ] **Service status**: `docker service ls` — all expected services show `1/1` replicas.
- [ ] **Health endpoints**: For each service, verify `/api/health` returns 200 (via `curl http://<service>:<port>/api/health`).
- [ ] **Sentry startup**: Check `Tasks/Logs/` for sentry startup log confirming fleet check-in.
- [ ] **Port registry**: Verify expected ports are listening: `docker service ps <service>` and check published ports.
- [ ] **Secret injection**: `docker service inspect <service>` shows secrets mounted correctly.
- [ ] **Telegram connection**: Bot responds to `/status` command.

---

## Red lines

- **Must have AWS SSO session**: SSO token is required for Secrets Manager and IAM provisioning. Run `aws sso login --profile intersite` before `deploy.ps1`.
- **Must run from PowerShell 7**: The script checks `PSVersionTable.PSVersion.Major` and will warn if < 7.
- **Must not skip credential phases without understanding consequences**: Phases 9a–10 create and isolate credentials. Skipping them on a re-run may leave stale or missing secrets.
- **Host-side only**: deploy.ps1 sets up the Docker host and should never run inside a container. It modifies system state (Docker Desktop, Swarm, BitLocker, Tailscale).
- **Deploy.ps1 will run again**: Fix the script, not the state. A runtime error is a failure of the script logic that will recur on the next run.
- **Phase dependency names must match invocation names exactly**: The `$PhaseDependencies` table keys must match the `-PhaseName` argument to `Invoke-DeployPhase`. Previously `DockerSwarm` (in deps) didn't match `Docker` (invocation), causing all downstream phases (ResourcePreflight, DockerSecrets, FleetDeploy) to be silently skipped via `Test-DeployPhasePrerequisites`. The `-notcontains` operator on a `$null` `$CompletedPhases` array (from a prior skipped phase returning `$null`) cascades the skip to every subsequent phase.

---

## Known Failure Modes

| # | Error symptom | Root cause | Fix | Files changed |
|---|---|---|---|---|
| 1 | Phase silently skipped (`[SKIP] Phase 'X' requires: Y`) | Phase dependency name mismatch in `$PhaseDependencies` — key name does not match the `-PhaseName` used in `Invoke-DeployPhase`. Or a prior skipped phase returned `$null`, setting `$CompletedPhases = $null` and cascading | Ensure every phase name in `$PhaseDependencies` matches the exact `-PhaseName` string. Fix `$CompletedPhases` return value to preserve prior state on skip | `Skills/Docker/deploy.ps1` |
| 2 | `[ref] cannot be applied to a variable that does not exist` | A `[ref]` parameter passed to a phase function targets a script-scoped variable that was never initialized | Initialize the variable with `$null` before the phase call | `Skills/Docker/deploy.ps1` |
| 3 | SSO login fails in DroneMode/NonInteractive | `Initialize-AwsSsoSession -NonInteractive` threw immediately without trying `--use-device-code`, which works in headless environments | Don't throw on `-NonInteractive` — fall through to device-code auth flow | `SalmonRun.Provision/Public/Initialize-AwsSsoSession.ps1` |
| 4 | Container exits on module load (empty path error) | `Get-ORCHESTRATORRepoRoot` walks up from `$PSScriptRoot` looking for `AGENTS.md`/`.git` — neither exists inside a Docker image, so it returns empty string | Set `$env:REPO_ROOT` before calling `Import-ORCHESTRATORModule`, or add `$env:REPO_ROOT` fallback in `Get-ORCHESTRATORRepoRoot` | `SalmonRun.Paths/SalmonRun.Paths.psm1`, container entrypoint script |
| 5 | SsoProfile null after phase 4 but SSL refresh at line 280 also fails | Both SSO attempts use `-NonInteractive` and fail, but the catch silently continues with `$SsoProfile = $null` | Fix SSO device-code auth; verify `$SsoProfile` before proceeding | `Initialize-AwsSsoSession.ps1` |

---

## Troubleshooting Resources

| Issue | Check |
|-------|-------|
| Phase X fails | `Tasks/Logs/setup-*.log` and `setup-warnings-*.log` |
| AWS SM access denied | Run `aws sso login --profile intersite` |
| Docker service not starting | `docker service logs <service>` |
| Port conflict | Check `Infrastructure/port-registry.json` for conflicts |
| General fleet health | `Skills/DevOps/Fleet/fleet-health/SKILL.md` |
| Secrets issues | `Skills/DevOps/Fleet/secrets/SKILL.md` |
| Troubleshooting guide | `Skills/DevOps/Fleet/troubleshoot/SKILL.md` |
