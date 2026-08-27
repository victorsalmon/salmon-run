<#
.SYNOPSIS
    Derives expected Docker Swarm services from fleet configuration.
.DESCRIPTION
    Uses role-stable naming (oc-base) instead of instance-ID names.
    Required services: ORCH, VERI, BASE (based on ROLE_CODE).
    Optional services: fleet, code-*.
.PARAMETER FleetConfig
    Hashtable from Resolve-FleetConfig. Defaults to a fresh resolution.
.OUTPUTS
    OrderedDictionary mapping service names to service metadata.
#>
function Get-FleetServiceMap {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [hashtable]$FleetConfig = (Resolve-FleetConfig)
    )

    $Map = [ordered]@{}
    $Stack = $FleetConfig.StackName

    foreach ($entry in $FleetConfig.AgentRoles) {
        $role = $entry.Role.ToUpper()
        $idx = $entry.Index
        $serviceName = Get-AgentServiceName -Role $role -Index $idx
        $Map["${Stack}_${serviceName}"] = @{
            Role     = $role
            Index    = $idx
            Required = $true
            Type     = "agent"
        }
    }

    if ($FleetConfig.InstallFleet -eq "true") {
        $Map["${Stack}_is-fleet"] = @{ Role = "fleet"; Required = $false; Type = "sidecar" }
    }
    if ($FleetConfig.InstallOpencode -eq "true") {
        $Map["${Stack}_mcp_opencode"] = @{ Role = "mcp_opencode"; Required = $false; Type = "mcp_opencode" }
    }

    return $Map
}
