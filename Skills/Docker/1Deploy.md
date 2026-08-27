# 1Deploy.ps1

Docker fleet deploy orchestrator for the ORCHESTRATOR stack.

## Purpose

Deploys the Docker Swarm stack using dynamic compose generation based on agent count and roles. Pulls the official ORCHESTRATOR image from GHCR, seeds config volumes (read-only) and persistence volumes (writable), and generates `docker-compose.interclaw.yml` per run.

## Parameters

| Parameter | Type | Mandatory | Description |
| :--- | :--- | :--- | :--- |
| `TargetDir` | string | Yes | Deployment target directory (workspace root) |
| `AgentConfigs` | hashtable[] | Yes | Array of agent configuration hashtables (`Role`, `Index`, `InstanceId`, `AgentName`, `GatewayPort`) |
| `ProjectCode` | string | Yes | Project code (e.g., `FRAD`) |
| `InstallN8n` | string | No | (Retired — n8n workflow hub removed) |
| `InstallTailscale` | string | No | Enable Tailscale subnet router (`true`/`false`, default `true`) |
| `InstallSentry` | string | No | Enable sentry runtime container (`true`/`false`, default `true`) |
| `InstallAgenticQE` | — | — | Removed. AQE tools (`mcp__agentic-qe__*`) are MCP-provided in every CODING/CONTROLLING container. No dedicated service. |
| `InstallCodeContainers` | string | No | Number of CODE workers to deploy (`0`-`5`, default `0` — set by `0setup.ps1`) |
| `InstallGithubToken` | string | No | Inject GitHub token for sentry git sync (`true`/`false`, default `false`) |
| `InstallWorkspaceRepos` | string | No | Comma-separated git repo URLs for shared workspace |
| `SovereigntyTier` | string | No | Sovereignty tier (`canada`/`usa`/`global`, default `global`) |
| `Phase` | string | No | Deployment phase to run (`All`/`Images`/`Volumes`/`Swarm`/`Compose`/`Deploy`/`Verify`/`Aliases`, default `All`) |

## Phase selector

| Phase | Actions |
| :--- | :--- |
| `Images` | Pull official image (`ORCHESTRATOR:local`), build sentry, code-worker, and api-proxy images |
| `Volumes` | Initialize agent config and persist volumes, clone workspace repos, seed AgenticQE if enabled |
| `Swarm` | Initialize Docker Swarm readiness |
| `Compose` | Set compose profile and generate fleet compose (skip deploy) |
| `Deploy` | Publish fleet stack to Docker Swarm |
| `Verify` | Run post-deploy fleet verification |
| `Aliases` | Generate PowerShell aliases for agent access |
| `All` | Run all phases in order |

## Environment variables consumed

| Variable | Source |
| :--- | :--- |
| `INSTALL_PROJECT` | Set by `0setup.ps1` |
| `COMPOSE_PROFILES` | Saved and restored by `1Deploy.ps1` |

## Usage

```powershell
# Full deployment (called by 0setup.ps1)
pwsh ./Scripts/1Deploy.ps1 -TargetDir ./ -AgentConfigs $agentConfigs -ProjectCode FRAD

# Docker-only rebuild (skip SSO and secrets)
pwsh ./Scripts/1Deploy.ps1 -TargetDir ./ -AgentConfigs $agentConfigs -ProjectCode FRAD -Phase All

# Rebuild only images
pwsh ./Scripts/1Deploy.ps1 -TargetDir ./ -AgentConfigs $agentConfigs -ProjectCode FRAD -Phase Images
```

## Notes

- Propagates deploy toggles to `$script:` scope so module functions can access them
- Restores `COMPOSE_PROFILES` to its previous value after execution
- Stack name defaults to `ProjectCode`; for single-agent fleets, uses the agent prefix
