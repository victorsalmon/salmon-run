<#
.SYNOPSIS
    Adds agent gateway services to the fleet compose definition.
.DESCRIPTION
    Iterates over agent configurations and appends gateway service entries with
    health checks, resource limits, secrets, volumes, and port bindings.
#>
function Add-AgentServiceToCompose {
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
        [string]$SovereigntyTier,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InstallWorkspaceRepos,
        [Parameter(Mandatory = $true)]
        [hashtable]$BundleManifest,
        [Parameter(Mandatory = $true)]
        [string]$AgentSuffix,
        [Parameter(Mandatory = $true)]
        [bool]$HasMultiple
    )
    Set-StrictMode -Off
    if (-not (Get-Command Get-ServicePort -ErrorAction SilentlyContinue)) {
        $null = Import-Module -Name SalmonRun.Ports -Force -DisableNameChecking -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 2>&1
    }
    $__ocConstants = Get-InterclawConstants
    $__agentImage = "`${ORCHESTRATOR_IMAGE:-$($__ocConstants.InterclawImage)}"

    for ($i = 0; $i -lt $Agents.Count; $i++) {
        $Agent = $Agents[$i]
        $SvcName = Get-AgentServiceName -Role $Agent.Role -Index $Agent.Index
        $Hostname = "$ProjectCode-$($Agent.Role.ToLower())-$($Agent.InstanceId)"
        $svcSecretPrefix = Get-AgentSecretPrefix -Project $ProjectCode -Role $Agent.Role -Index $Agent.Index

        $HealthCheckTest = @(
            'CMD-SHELL'
            "node -e `"fetch('http://127.0.0.1:18789/healthz').then(r=>{if(!r.ok)throw 1}).then(()=>process.exit(0)).catch(()=>process.exit(1))`""
        )

        $Service = [ordered]@{
            deploy      = [ordered]@{
                resources = [ordered]@{
                    reservations = [ordered]@{
                        memory = "2G"
                    }
                    limits = [ordered]@{
                        memory = "4G"
                    }
                }
                restart_policy = [ordered]@{
                    condition = "any"
                    delay     = "5s"
                }
            }
            image       = $__agentImage
            networks    = @((Get-NetworkNames).ServiceNet, (Get-NetworkNames).OrchestrationNet) # fleet-only: proxy_net, accountant_net removed
            entrypoint  = @("/bin/sh", "/home/node/.ORCHESTRATOR/entrypoint.sh", "node", "openclaw.mjs", "gateway", "--allow-unconfigured")
            labels      = [ordered]@{
                "interclaw.managed"          = "true"
                "interclaw.created-at"       = "{{.CreatedAt}}"
                "SalmonRun.Deploy-version"   = "1.0"
                "interclaw.service-type"     = "gateway"
            }
            environment = [ordered]@{
                INTERCLAW_INSTANCE_ID    = $Agent.InstanceId
                ORCHESTRATOR_PROJECT       = $ProjectCode
                ORCHESTRATOR_ROLE          = $Agent.Role
                INTERCLAW_AGENT_NAME    = $Agent.AgentName
                INTERCLAW_SOVEREIGNTY   = $SovereigntyTier
                INTERCLAW_DISABLE_BONJOUR = "1"
            }
            volumes     = @(
                "agent_config_${SvcName}:/app/.agent:ro"
                "agent_persist_${SvcName}:/home/node/.ORCHESTRATOR"
                "interclaw_logs:/shared/logs"
            )
            secrets     = @(
                [ordered]@{
                    source = "${svcSecretPrefix}_$AgentSuffix"
                    target = "secrets_bundle"
                }
            )
        }

        if (-not [string]::IsNullOrWhiteSpace($InstallWorkspaceRepos)) {
            $Service.volumes += "interclaw_workspace:/workspace"
            $Service.environment["WORKSPACE_REPOS"] = $InstallWorkspaceRepos
        }

        $GatewayHostPort = Get-AgentHostPort -Role $Agent.Role -Index $Agent.Index
        $Service.ports = @("$($GatewayHostPort):18789")

        $Service.secrets += [ordered]@{
            source = "gateway_password"
            target = "gateway_password"
        }

        if ($HasMultiple) {
            $Service.environment["TRIO_NETWORK"] = "orchestration_net"
            $Service.volumes += "memory_shared:/home/node/.ORCHESTRATOR/memory_daily"
        }

        if ($Agent.CrmAccess) {
            $Service.secrets += [ordered]@{
                source = "ATTIO_READ_KEY"
                target = "ATTIO_READ_KEY"
            }
        }

        $RepoRoot = Get-InterclawRepoRoot
        $Service.volumes += "${RepoRoot}/Tasks:/workspace/Fleet Tasks:ro"
        $orchOutbox = Join-Path $RepoRoot "workspace" "ORCH Outbox"
        $Service.volumes += "${orchOutbox}:/workspace/ORCH Outbox:ro"

        $Compose.services[$SvcName] = $Service
    }

    return $Compose
}
