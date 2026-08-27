# 1Install.ps1

First-time host provisioner for ORCHESTRATOR.

## Purpose

Installs all prerequisites on a fresh Windows machine. Handles only software installation — authentication and fleet configuration belong in `0setup.ps1`.

## Prerequisites installed

| Software | Source | Notes |
| :--- | :--- | :--- |
| WSL2 | Windows feature | Requires build 1903+ |
| Virtual Machine Platform | Windows feature | Required for WSL2 |
| PowerShell 7 | Winget (`Microsoft.PowerShell`) | Verified on PATH after install |
| Git | Winget (`Git.Git`) | |
| AWS CLI | Winget (`Amazon.AWSCLI`) | |
| Docker Desktop | Winget (`Docker.DockerDesktop`) | WSL2 backend pre-configured |
| Tailscale | Winget (`Tailscale.Tailscale`) | Auto-login attempted |

## What it does

1. **Elevates to administrator** if not already running as admin (required for DISM/Winget)
2. **Windows version check** — verifies build 1903+ for WSL2
3. **WSL2 features** — enables `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform`
4. **Winget installs** — idempotent install of all required applications
5. **Repository clone** — clones `intersite-orchestrator` to `~/intersite-orchestrator`
6. **Config directory** — creates `~/.ORCHESTRATOR/` and prompts for `install.json` values (saved to repo root)
7. **AWS SSO bootstrap** — writes `~/.aws/config` with SSO session and profile
8. **Docker Desktop config** — pre-configures WSL2 backend, auto-start, dark theme
9. **Restart handling** — auto-restarts if WSL2 features were just enabled (resumes via RunOnce)
10. **Docker readiness** — polls Docker daemon for up to 150 seconds
11. **Tailscale** — verifies installation and attempts login

## Interactive prompts

| Prompt | Default | Description |
| :--- | :--- | :--- |
| Project code | `FRA` | 1-4 character fleet identifier |
| Number of agents | `1` | How many agents to deploy |
| Role codes | `ORCH` | Comma-separated roles (ORCH, WORK, VERI, BASE) |
| SSO profile name | `default` | AWS SSO profile name |
| AWS region | `ca-central-1` | Default AWS region |

## Usage

```powershell
# Run directly (auto-elevates if needed)
pwsh ./Scripts/1Install.ps1
```

## Notes

- Sets `RunOnce` registry entry to resume `0setup.ps1` after reboot
- Does NOT handle AWS SSO login — that happens in `0setup.ps1`
- `install.json` is loaded non-destructively by downstream scripts
- If PowerShell 7 is not on PATH after install, prompts to restart terminal
