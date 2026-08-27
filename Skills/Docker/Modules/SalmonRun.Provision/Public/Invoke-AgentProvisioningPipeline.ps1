<#
.SYNOPSIS
Runs the full provisioning pipeline for all agents in a fleet.

.DESCRIPTION
Iterates over all agent roles and invokes the provisioning script
(1Provision.ps1) for each agent. Runs Secrets hydration first, then AWS
provisioning if enabled. Collects results and reports any failures.

.PARAMETER AgentRoles
Array of agent role objects, each containing Role, Index, and InstanceId.

.PARAMETER ProjectCode
The project code used for agent naming and environment variables.

.PARAMETER RoleNameMap
Hashtable mapping role codes to custom display names.

.PARAMETER ScriptRoot
Root directory containing the 1Provision.ps1 script.
#>
function Invoke-AgentProvisioningPipeline {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [array]$AgentRoles,
        [Parameter(Mandatory)]
        [string]$ProjectCode,
        [Parameter(Mandatory)]
        [hashtable]$RoleNameMap,  # Key: role code (string), Value: custom display name (string)
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )
    $InstallAws = "true"
    $agentResults = $AgentRoles | ForEach-Object {
        $AgentRole = $_
        $CurrentRole = $AgentRole.Role
        $CurrentIndex = $AgentRole.Index
        $CurrentInstanceId = $AgentRole.InstanceId
        $CurrentAgentName = "Agent-$ProjectCode-$CurrentRole-$CurrentInstanceId"
        $CurrentGatewayPort = Get-AgentHostPort -Role $CurrentRole -Index $CurrentIndex

        Write-Verbose "`n========================================"
        Write-Verbose "  AGENT $CurrentRole-$CurrentInstanceId : $CurrentAgentName"
        Write-Verbose "========================================"

        Set-Item -Path "Env:\INSTALL_PROJECT" -Value $ProjectCode
        Set-Item -Path "Env:\INSTALL_ROLE" -Value $CurrentRole
        Set-Item -Path "Env:\INTERCLAW_INSTANCE_ID" -Value $CurrentInstanceId
        Set-Item -Path "Env:\INTERCLAW_AGENT_INDEX" -Value $CurrentIndex
        Set-Item -Path "Env:\INTERCLAW_AGENT_NAME" -Value $CurrentAgentName
        Set-Item -Path "Env:\HOST_PORT_GATEWAY" -Value $CurrentGatewayPort

        $AgentCtx = New-AgentContext -ProjectCode $ProjectCode -RoleCode $CurrentRole -InstanceId $CurrentInstanceId -Index $CurrentIndex

        try {
            & (Join-Path $ScriptRoot "1Provision.ps1") -Phase Secrets -AgentContext $AgentCtx -ErrorAction Stop
        } catch {
            return @{ Error = "Hydration failed for $CurrentAgentName`: $_" }
        }

        if ($InstallAws -eq "true") {
            try {
                & (Join-Path $ScriptRoot "1Provision.ps1") -Phase AWS -AgentContext $AgentCtx -ErrorAction Stop
            } catch {
                return @{ Error = "AWS provisioning failed for $CurrentAgentName`: $_" }
            }
        }

        $CustomName = if ($RoleNameMap.ContainsKey($CurrentRole)) { $RoleNameMap[$CurrentRole] } else { $null }
        return @{
            Role = $CurrentRole; Index = $CurrentIndex; InstanceId = $CurrentInstanceId
            AgentName = $CurrentAgentName; GatewayPort = $CurrentGatewayPort
            CustomName = $CustomName;
            DisplayName = if ($CustomName) { "$CustomName ($CurrentRole-$CurrentInstanceId)" } else { "$CurrentRole-$CurrentInstanceId" }
        }
    }

    $agentConfigs = @($agentResults | Where-Object { -not $_.ContainsKey('Error') })
    $failedResults = @($agentResults | Where-Object { $_.ContainsKey('Error') })
    if ($failedResults.Count -gt 0) {
        foreach ($f in $failedResults) {
            Write-Warning "  [FAIL] $($f.Error)"
            Write-SetupLog "$($f.Error)" -Level ERROR
        }
        throw "$($failedResults.Count) agent(s) failed provisioning"
    }
    $provisionedIds = $agentConfigs | ForEach-Object { $_.InstanceId }
    return @{ AgentConfigs = $agentConfigs; ProvisionedIds = $provisionedIds }
}
