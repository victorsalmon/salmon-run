<#
.SYNOPSIS
    Starts the HTTP health listener for the fleet container.
.DESCRIPTION
    Runs an HTTP listener on the specified port. Serves fleet health,
    readiness, and log collection endpoints. State is maintained internally
    and updated via POST to /update-state from the main loop, avoiding
    cross-process serialization issues with Start-Job.
.PARAMETER Port
    HTTP listener port. Defaults to Get-ServicePort -Service "is-fleet" -Type "internal".
.PARAMETER Prefix
    HTTP URL prefix for the listener. Defaults to http://+:${Port}/.
.OUTPUTS
    None. Runs as a background listener.
#>
function Start-FleetHealthListener {
    [OutputType([void])]
    param(
        [int]$Port = (Get-ServicePort -Service "is-fleet" -Type "internal"),
        [string]$Prefix = "http://+:${Port}/"
    )
    if ((Get-InterclawConstants) -and (Get-InterclawConstants).FleetApiPort) {
        $Port = (Get-InterclawConstants).FleetApiPort; $Prefix = "http://+:$Port/"
    }
    $fleetMonitorToken = Get-Content "/run/secrets/fleet_monitor_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    $fleetApiToken = Get-Content "/run/secrets/fleet_api_token" -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
    if ([string]::IsNullOrWhiteSpace($fleetApiToken) -and [string]::IsNullOrWhiteSpace($fleetMonitorToken)) {
        Write-Error "FATAL: Both fleet monitor and api tokens are empty — listener not started"
        return
    }
    if ([string]::IsNullOrWhiteSpace($fleetApiToken)) { Write-Warning "fleet_api_token is empty — write endpoints will reject all requests" }
    if ([string]::IsNullOrWhiteSpace($fleetMonitorToken)) { Write-Warning "fleet_monitor_token is empty — read endpoints will reject all requests" }
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $ListenerJob = Start-Job -ScriptBlock {
        param($Prefix, $ModuleRoot)
        if ($ModuleRoot -and (Test-Path "$ModuleRoot/Private/Invoke-FleetDockerExec.ps1")) { . "$ModuleRoot/Private/Invoke-FleetDockerExec.ps1" }
        if ($ModuleRoot -and (Test-Path "$ModuleRoot/Private/Invoke-FleetHealthHelpers.ps1")) { . "$ModuleRoot/Private/Invoke-FleetHealthHelpers.ps1" }
        if ($ModuleRoot -and (Test-Path "$ModuleRoot/Private/Invoke-FleetHealthHandlers.ps1")) { . "$ModuleRoot/Private/Invoke-FleetHealthHandlers.ps1" }
        $CurrentState = @{ StartTime = [DateTime]::UtcNow; Status = "starting"; LastUpdate = $null; FailCount = 0; Version = $null; Hostname = $null; StackName = $null }  # used by dot-sourced Invoke-FleetHealthHandlers.ps1
        $restartAllowedServices = @("mcp_opencode", "mcp_browserless", "is-bookkeeping", "ops-funnel-proxy", "is-marketer")  # used by dot-sourced Invoke-FleetHealthHandlers.ps1
        $script:RateLimiter = New-InlineRateLimiter -Limit 100 -WindowSec 60
        Invoke-HealthListenerLoop -Prefix $Prefix
    } -ArgumentList $Prefix, $moduleRoot
    return $ListenerJob
}
