<#
.SYNOPSIS
    Agent identity and resource naming for SalmonRun.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
Import-Module SalmonRun.Constants -Force -DisableNameChecking -ErrorAction Stop

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
    'Resolve-AgentIdentity',
    'Resolve-AgentNames',
    'Resolve-SovereigntyTier',
    'Test-CodingKeyAvailability',
    'Get-AgentHostPort',
    'Get-AgentServiceName',
    'Get-AgentVolumeName',
    'Get-AgentSecretPrefix',
    'Get-RoleFileMap',
    'Get-SharedFiles',
    'New-AgentContext',
    'Initialize-FleetToggles'
)
