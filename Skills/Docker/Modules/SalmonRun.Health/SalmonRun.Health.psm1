<#
.SYNOPSIS
    Fleet health check probes for SalmonRun.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
$PrivatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $PrivatePath) {
    Get-ChildItem -Path $PrivatePath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'Test-FleetStackHealth',
    'Test-FleetCodeHealth',
    'Test-FleetVolumeIntegrity',
    'Test-FleetSecretHydration',
    'Test-FleetContainerHealth',
    'Test-FleetSecretResolution',
    'Test-FleetNetworkConnectivity',
    'Test-FleetSidecarHealth',
    'Test-FleetSelfHealth',
    'Test-FleetTelegramPolling',
    'Test-FleetAqeTopology',
    'Test-FleetSwarmReality',
    'Test-FleetServiceEndpoints'
)
