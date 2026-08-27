<#
.SYNOPSIS
    Starts an HTTP listener for operational API endpoints on Fleet.
#>
function Start-FleetOperationalListener {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Job])]
    param([Parameter()][int]$Port = 29997)

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $ListenerJob = Start-Job -ScriptBlock {
        param($Port, $ModuleRoot)
        if ($ModuleRoot -and (Test-Path "$ModuleRoot/Private/Invoke-FleetOperationalHelpers.ps1")) { . "$ModuleRoot/Private/Invoke-FleetOperationalHelpers.ps1" }
        Invoke-OperationalListenerLoop -Port $Port
    } -ArgumentList $Port, $moduleRoot

    return $ListenerJob
}
