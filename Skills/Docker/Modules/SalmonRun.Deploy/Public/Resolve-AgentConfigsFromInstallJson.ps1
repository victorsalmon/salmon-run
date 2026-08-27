<#
.SYNOPSIS
    Reads install.json and resolves agent configurations with ports and context.
.DESCRIPTION
    Parses the fleet.agents array from install.json, assigns instance IDs and
    gateway ports, creates AgentContext objects, and returns config hashtables.
#>
function Resolve-AgentConfigsFromInstallJson {
    [OutputType([System.Object[]])]
    param(
        [string]$InstallJsonPath,
        [string]$ProjectCode
    )
    $installJson = Read-InstallJson -Path $InstallJsonPath -ErrorAction SilentlyContinue
    if (-not $installJson -or -not $installJson.fleet -or -not $installJson.fleet.agents -or $installJson.fleet.agents.Count -eq 0) {
        return @()
    }
    $globalCounter = 1
    $roleIndexCounts = @{}
    $configs = @()
    foreach ($agent in $installJson.fleet.agents) {
        $role = $agent.role
        $name = $agent.name
        $idx = if ($roleIndexCounts.ContainsKey($role)) { $roleIndexCounts[$role] + 1 } else { 0 }
        $roleIndexCounts[$role] = $idx
        $instanceId = $globalCounter.ToString()
        $globalCounter++
        $agentName = "Agent-${ProjectCode}-${role}-${instanceId}"
        $gatewayPort = Get-AgentHostPort -Role $role -Index $idx -ErrorAction SilentlyContinue
        $agentCtx = New-AgentContext -ProjectCode $ProjectCode -RoleCode $role -InstanceId $instanceId -Index $idx
        $configs += @{
            Role        = $role
            Index       = $idx
            InstanceId  = $instanceId
            AgentName   = $agentName
            GatewayPort = $gatewayPort
            CustomName  = $name
            DisplayName = if ($name) { "$name ($role-$instanceId)" } else { "$role-$instanceId" }
            AgentCtx    = $agentCtx
        }
    }
    return $configs
}
