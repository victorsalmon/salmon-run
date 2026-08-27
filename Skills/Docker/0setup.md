# 0setup.ps1

Master orchestrator script for the ORCHESTRATOR fleet deployment.

## Purpose

Coordinates the entire provisioning and deployment lifecycle:
1. Host readiness check (Docker, Git, AWS CLI, PowerShell 7)
2. Identity wizard (project code, roles, instance IDs, sovereignty tier, SSO profile)
3. CODE worker configuration (`INSTALL_CODE_CONTAINERS` 0-5, backward-compatible with `INSTALL_OPENCODE`)
4. Per-agent provisioning loop (secrets, IAM, Bedrock)
5. Docker image builds (sentry, code-worker)
6. Fleet deployment via `1Deploy.ps1`
7. Credential cleanup

## Parameters

| Parameter | Type | Description |
| :--- | :--- | :--- |
| `AutoReboot` | switch | Automatically reboot after host provisioning if needed (deprecated — use `-DroneMode` for headless rebuilds) |
| `DroneMode` | switch | Headless fleet rebuild mode for running inside container. Reads `install.json` + AWS credentials directly |

## Environment variables set

| Variable | Example | Description |
| :--- | :--- | :--- |
| `ORCHESTRATOR_RUN_ID` | `1a19be53` | Correlation ID for all logs in this run |
| `ORCHESTRATOR_SETUP_LOG` | `.../setup-20260423-172658.log` | Path to setup log file |
| `INSTALL_PROJECT` | `FRAD` | Project code |
| `ROLE_CODE` | `ORCH,VERI` | Comma-separated agent roles |
| `AGENT_NUMBER` | `2` | Number of agents to deploy |
| `INSTALL_N8N` | (retired) | n8n workflow hub — retired |
| `INSTALL_TAILSCALE` | `true` | Enable Tailscale subnet router |
| `INSTALL_SENTRY` | `true` | Enable sentry runtime container |
| `INSTALL_AGENTIC_QA` | — | Removed. AQE tools are MCP-provided in every CODING/CONTROLLING container. |
| `INSTALL_CODE_CONTAINERS` | `2` | Number of CODE containers (0–5). Backward-compatible with deprecated `INSTALL_OPENCODE` |
| `SOVEREIGNTY_TIER` | `global` | Canada / USA / Global |
| `AWS_SSO_PROFILE` | `interclaw` | AWS SSO profile name |

## Usage

```powershell
# Interactive run
pwsh ./Scripts/0setup.ps1

# Auto-reboot if host provisioning is needed
pwsh ./Scripts/0setup.ps1 -AutoReboot
```

## Phase breakdown

| Phase | Script | Description |
| :--- | :--- | :--- |
| Step | Script | Description |
| :--- | :--- | :--- |
| 0 | `1Install.ps1` | Host provisioning (if Docker/Git missing) |
| 1 | `0setup.ps1` | Identity wizard, SSO login, sidecar toggles, workspace repos |
| 2 | `1Provision.ps1 -Phase Secrets` | Secret hydration per agent |
| 3 | `1Provision.ps1 -Phase AWS` | IAM + Bedrock + credential isolation per agent |
| 4 | `1Deploy.ps1 -Phase All` | Image pull + builds, volume seed, swarm init, compose gen, deploy, verify, aliases |
| 5 | `0setup.ps1` | Post-deploy health check, persist config |
| 6 | `0setup.ps1` | Credential cleanup + VHD compaction |

## Notes

- If the host is not ready, the script registers itself in `RunOnce` registry to resume after reboot
- Generates a unique `ORCHESTRATOR_RUN_ID` for log correlation across all downstream scripts
- Loads `Modules/ORCHESTRATOR.Core/ORCHESTRATOR.Core.ps1` for shared helper functions
