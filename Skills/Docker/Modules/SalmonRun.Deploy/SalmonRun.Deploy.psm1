<#
.SYNOPSIS
    Fleet compose generation, YAML serialization, stack deployment, image seeding, and startup verification for Interclaw.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-ComposeYaml',
    'ConvertTo-ComposeYamlScalar',
    'Copy-FilesToVolume',
    'Get-FleetServiceMap',
    'Get-ImageSourceHash',
    'Initialize-AgentVolumes',
    'Initialize-HermesData',
    'Initialize-SwarmReadiness',
    'Invoke-AgentReseed',
    'Invoke-ImagePull',
    'Invoke-InterclawDeployment',
    'Invoke-PrePullBaseImages',
    'New-FleetAliases',
    'New-FleetCompose',
    'New-FleetDeploymentOptions',
    'Publish-FleetStack',
    'Receive-ParallelImageBuild',
    'Remove-OrphanedVolumes',
    'Resolve-WorkspaceRepos',
    'Test-FleetDeployment',
    'Write-DeployManifest',
    'Resolve-AgentConfigsFromInstallJson',
    'Add-AgentServiceToCompose',
    'Add-FleetServiceToCompose',
    'Add-SidecarServicesToCompose',
    'Add-ComposeNetworksAndVolumes',
    'Add-ComposeSecrets',
    'Compile-FleetComposeOutput',
    'Test-DeployPhasePrerequisites',
    'Invoke-DeployPhase',
    'Invoke-WhatIfGuard',
    'Restrict-FileAccess',
    'Invoke-DeployPhaseIamAndBedrock',
    'Invoke-DeployPhaseOrchestratorInfra',
    'Invoke-DeployPhaseCredentialIsolation',
    'Invoke-DeployPhaseDockerSecrets',
    'Invoke-DeployPhaseFleetDeploy'
)
