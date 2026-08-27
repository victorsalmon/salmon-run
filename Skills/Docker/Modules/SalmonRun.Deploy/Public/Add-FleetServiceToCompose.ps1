<#
.SYNOPSIS
    Adds the is-fleet management service to the fleet compose definition.
.DESCRIPTION
    Creates the fleet orchestrator service entry with Docker socket mount,
    health checks, resource limits, and environment configuration.
#>
function Add-FleetServiceToCompose {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Compose,
        [Parameter(Mandatory = $true)]
        [hashtable[]]$Agents,
        [Parameter(Mandatory = $true)]
        [string]$ProjectCode,
        [Parameter(Mandatory = $true)]
        [string]$BundleNameFleet,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstallWorkspaceRepos,
        [Parameter(Mandatory = $true)]
        [bool]$PreserveFleet,
        [Parameter(Mandatory = $true)]
        [bool]$FleetEnabled
    )
    $preserveFleetEffective = $PreserveFleet -or ($env:INTERCLAW_PRESERVE_FLEET -eq "true")
    if ($FleetEnabled -and -not $preserveFleetEffective) {
        # With the openclaw agent layer retired, Agents may be empty. Use
        # placeholder values so is-fleet still gets valid env vars.
        $FirstAgent = if ($Agents.Count -gt 0) { $Agents[0] } else { @{
            InstanceId = '0'; Role = 'BASE'; Index = 0; AgentName = 'fleet-standalone'
        } }
        $HomeDirPath = (Get-HomeDir)
        $DeployRepoRoot = Get-InterclawRepoRoot
        $FleetHostPort = Get-ServicePort -Service "is-fleet" -Type "host"
        $FleetInternalPort = Get-ServicePort -Service "is-fleet" -Type "internal"
        $FleetService = [ordered]@{
            image       = "`${ORCHESTRATOR_FLEET_IMAGE:-$((Get-InterclawConstants).FleetImage)}"
            networks    = @((Get-NetworkNames).ServiceNet, (Get-NetworkNames).ManagementNet)
            ports       = @("127.0.0.1:${FleetHostPort}:${FleetInternalPort}")
            healthcheck = [ordered]@{
                test         = @("CMD-SHELL", "curl -sf http://127.0.0.1:${FleetInternalPort}/health || exit 1")
                interval     = "30s"
                timeout      = "10s"
                retries      = 3
                start_period = "30s"
            }
            deploy      = [ordered]@{
                resources = [ordered]@{
                    reservations = [ordered]@{
                        memory = "512M"
                    }
                    limits = [ordered]@{
                        memory = "`${FLEET_MEMORY_LIMIT:-1G}"
                    }
                }
                restart_policy = [ordered]@{
                    condition    = "any"
                    delay        = "5s"
                    max_attempts = 5
                }
            }
            volumes     = @(
                "/var/run/docker.sock:/var/run/docker.sock"
                "$HomeDirPath/.ORCHESTRATOR:/home/node/.ORCHESTRATOR"
                "$DeployRepoRoot/Tasks/Logs:/home/node/.ORCHESTRATOR/workspace/reports"
                "interclaw_logs:/shared/logs"
                "$DeployRepoRoot/install.json:/home/node/app/install.json"
            )
            environment = [ordered]@{
                INTERCLAW_INSTANCE_ID   = $FirstAgent.InstanceId
                INSTALL_PROJECT        = $ProjectCode
                INSTALL_ROLE           = $FirstAgent.Role
                INTERCLAW_SECRET_PREFIX = Get-AgentSecretPrefix -Project $ProjectCode -Role $FirstAgent.Role -Index $FirstAgent.Index
                INTERCLAW_AGENT_NAME    = $FirstAgent.AgentName
                REBUILD_INTERCLAW       = "false"
                AWS_SSO_PROFILE        = '${AWS_SSO_PROFILE}'
                GITHUB_USERNAME        = $env:GITHUB_USERNAME ?? "ORCHESTRATOR-bot"
                REPO_DIR               = "/workspace/repo"
                TASK_POLL_INTERVAL     = "10"
                STALL_TIMEOUT          = "300"
            }
            secrets     = @(
                [ordered]@{
                    source = $BundleNameFleet
                    target = "secrets_bundle"
                }
                [ordered]@{ source = "FLEET_API_TOKEN_FLEET"; target = "fleet_api_token" }
                [ordered]@{ source = "FLEET_API_TOKEN_MONITOR"; target = "fleet_monitor_token" }
            )
            labels      = [ordered]@{
                "interclaw.managed"          = "true"
                "interclaw.created-at"       = "{{.CreatedAt}}"
                "SalmonRun.Deploy-version"   = "1.0"
                "interclaw.service-type"     = "is-fleet"
            }
            cap_drop    = @("ALL")
            cap_add     = @("CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID", "NET_BIND_SERVICE")
            security_opt = @("no-new-privileges:true")
            read_only   = $true
            tmpfs       = @("/tmp", "/home/node/.docker", "/home/node/app/Tasks/Logs")
            entrypoint  = @("pwsh", "-File", "/home/node/app/Scripts/1Fleet.ps1", "-Mode", "Entrypoint")
        }

        if (-not [string]::IsNullOrWhiteSpace($InstallWorkspaceRepos)) {
            $FleetService.volumes += "interclaw_workspace:/workspace/repo"
        }
        else {
            $FleetService.volumes += @(
                "$DeployRepoRoot/Tasks/Schedule:/workspace/repo/Tasks/Schedule"
                "$DeployRepoRoot/Tasks/Code:/workspace/repo/Tasks/Code"
            )
        }

        $Compose.services["is-fleet"] = $FleetService
    }

    return $Compose
}
