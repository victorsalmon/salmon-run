<#
.SYNOPSIS
    Adds network and volume definitions to the fleet compose object.
.DESCRIPTION
    Registers service, orchestration, management, and funnel networks along with
    per-agent config/persist volumes and shared logging volume.
#>
function Add-ComposeNetworksAndVolumes {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Compose,
        [hashtable[]]$Agents,
        [Parameter(Mandatory = $true)]
        [string]$InstallFunnel,
        [string]$InstallWorkspaceRepos = "",
        [Parameter(Mandatory = $true)]
        [bool]$HasMultiple
    )

    $Compose.networks[(Get-NetworkNames).ServiceNet] = [ordered]@{ external = $true }
    $Compose.networks[(Get-NetworkNames).OrchestrationNet] = [ordered]@{
        external = $true
    }
    $Compose.networks[(Get-NetworkNames).ManagementNet] = [ordered]@{
        external = $true
    }
    if ($InstallFunnel -eq "true") {
        $Compose.networks[(Get-NetworkNames).FunnelNet] = [ordered]@{
            external = $true
            name     = "funnel_net"
        }
    }

    for ($i = 0; $i -lt $Agents.Count; $i++) {
        $svcName = Get-AgentServiceName -Role $Agents[$i].Role -Index $Agents[$i].Index
        $Compose.volumes["agent_config_${svcName}"] = $null
        $Compose.volumes["agent_persist_${svcName}"] = $null
    }
    if ($HasMultiple) {
        $Compose.volumes["memory_shared"] = $null
    }

    # Shared workspace volume — mounted by opencode and (optionally) by agents
    # when workspace repos are configured. The actual volume is prefixed with
    # the Swarm stack name, so point the compose volume name to it.
    $wsStackName = if (Get-Command Get-StackName -ErrorAction SilentlyContinue) { Get-StackName } else { $env:INSTALL_PROJECT }
    if ([string]::IsNullOrWhiteSpace($wsStackName)) { $wsStackName = "interclaw" }
    $Compose.volumes["interclaw_workspace"] = [ordered]@{
        external = $true
        name     = "${wsStackName}_interclaw_workspace"
    }

    # Shared logging volume — mounted at /shared/logs for all services
    $Compose.volumes["interclaw_logs"] = $null

    return $Compose
}
