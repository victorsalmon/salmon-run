<#
.SYNOPSIS
    Starts an HTTP endpoint for rotating individual Docker Swarm secrets.
.DESCRIPTION
    Listens for POST /secret/update requests on the specified port.
    Accepts JSON body with container, key, and value fields.
    Reads the current secret bundle from the target container, verifies
    the new value length matches the current secret, then performs an
    atomic rotation (create new bundle -> service update -> remove old).
    Only operates on keys existing in the target container's secret bundle
    (Interclaw/FRAD/Orchestrator scope, not Provisioning).
.PARAMETER Port
    HTTP listener port. Default 29998.
.PARAMETER AllowedContainers
    Container/service names allowed for rotation. Default @("oc-base", "is-fleet").
#>
function Start-SecretRotationEndpoint {
    [OutputType([bool])]
    param(
        [int]$Port = 29998,
        [string[]]$AllowedContainers = @("oc-base", "is-fleet", "is-bookkeeping", "mcp_browserless", "mcp_opencode")
    )

    $Prefix = "http://+:$Port/"
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $RotationJob = Start-Job -ScriptBlock {
        param($Prefix, $AllowedContainers, $ModuleRoot)

        if ($ModuleRoot -and (Test-Path "$ModuleRoot/Private/Invoke-FleetDockerExec.ps1")) { . "$ModuleRoot/Private/Invoke-FleetDockerExec.ps1" }
        if ($ModuleRoot -and (Test-Path "$ModuleRoot/Private/Invoke-FleetRotationHelpers.ps1")) { . "$ModuleRoot/Private/Invoke-FleetRotationHelpers.ps1" }

        Invoke-RotationListenerLoop -Prefix $Prefix -AllowedContainers $AllowedContainers
    } -ArgumentList $Prefix, $AllowedContainers, $moduleRoot

    return $RotationJob
}
