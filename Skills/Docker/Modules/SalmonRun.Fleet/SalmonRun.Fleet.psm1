<#
.SYNOPSIS
    Fleet runtime: entrypoint loop, fleet health checks, service remediation, startup verification, and system updates for SalmonRun.
#>
#Requires -Version 7.0

Set-StrictMode -Off

if ($script:SalmonRunFleetLoaded) { return }
$script:SalmonRunFleetLoaded = $true

$script:ModuleRoot = $PSScriptRoot
$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

. $PSScriptRoot\Private\fleet-state.ps1
. $PSScriptRoot\Private\rate-limiter.ps1
. $PSScriptRoot\Private\Invoke-FleetDockerExec.ps1
. $PSScriptRoot\Private\Invoke-FleetHealthHelpers.ps1
. $PSScriptRoot\Private\Invoke-FleetHealthHandlers.ps1
. $PSScriptRoot\Private\Invoke-FleetOperationalHelpers.ps1
. $PSScriptRoot\Private\Invoke-FleetRotationHelpers.ps1

Export-ModuleMember -Function @(
    'Format-FleetHealthReport',
    'Get-ActiveAgentIds',
    'Get-ActiveAgentRoles',
    'Get-FleetHealthState',
    'Get-StackName',
    'Invoke-FleetContainerRedeploy',
    'Invoke-FleetEntrypoint',
    'Invoke-FleetFailureTracker',
    'Invoke-FleetHealthCheck',
    'Invoke-FleetRebuild',
    'Invoke-FleetRemediation',
    'Invoke-FleetStartupCheck',
    'Invoke-FleetStartupVerification',
    'Invoke-RemedyWithRetry',
    'Read-FleetSecret',
    'Start-FleetHealthListener',
    'Start-FleetOperationalListener',
    'Start-SecretRotationEndpoint',
    'Test-FleetAqeTopology',
    'Test-FleetCodeHealth',
    'Test-FleetContainerHealth',
    'Test-FleetNetworkConnectivity',
    'Test-FleetSecretHydration',
    'Test-FleetSecretResolution',
    'Test-FleetSelfHealth',
    'Test-FleetServiceEndpoints',
    'Test-FleetSidecarHealth',
    'Test-FleetStackHealth',
    'Test-FleetSwarmReality',
    'Test-FleetTelegramPolling',
    'Test-FleetVolumeIntegrity',
    'Update-FleetHealthState',
    'Write-FleetLog'
)
