# Boundary: Docker API — fleet compose, stack deploy, volume management
@{
    RootModule = 'SalmonRun.Deploy.psm1'
    ModuleVersion = '1.0.0'
    GUID = '8a33b473-3fb8-4304-99ee-3e1c68aa5ebc'
    Author = 'Interclaw'
    Description = 'Deployment module for Interclaw fleet compose generation and stack deployment'
    PowerShellVersion = '7.0'
    # Uses: Core (Get-BackoffDelay, Invoke-DockerWithLogging, Write-AtomicFile), Paths (Get-InterclawRepoRoot), Ports (Get-ServicePort), Diagnostics (Write-SetupLog, Get-ReportsDir)
    # Config removed — transitively available via Identity and Secrets
    RequiredModules   = @('SalmonRun.Core', 'SalmonRun.Diagnostics', 'SalmonRun.Identity', 'SalmonRun.Secrets', 'SalmonRun.Images', 'SalmonRun.Process', 'SalmonRun.Provision')
    FunctionsToExport = @(
        'Get-FleetServiceMap'
        'Initialize-AgentVolumes'
        'Test-FleetDeployment'
        'New-FleetCompose'
        'ConvertTo-ComposeYaml'
        'ConvertTo-ComposeYamlScalar'
        'Copy-FilesToVolume'
        'Initialize-SwarmReadiness'
        'Invoke-ImagePull'
        'Get-ImageSourceHash'
        'Invoke-InterclawDeployment'
        'New-FleetAliases'
        'Receive-ParallelImageBuild'
        'Publish-FleetStack'
        'New-FleetDeploymentOptions'
        'Remove-OrphanedVolumes'
        'Resolve-WorkspaceRepos'
        'Invoke-AgentReseed',
        'Invoke-PrePullBaseImages',
        'Write-DeployManifest',
        'Resolve-AgentConfigsFromInstallJson'
        'Add-AgentServiceToCompose'
        'Add-FleetServiceToCompose'
        'Add-SidecarServicesToCompose'
        'Add-ComposeNetworksAndVolumes'
        'Add-ComposeSecrets'
        'Compile-FleetComposeOutput'
        'Test-DeployPhasePrerequisites'
        'Invoke-DeployPhase'
        'Invoke-WhatIfGuard'
        'Restrict-FileAccess'
        'Invoke-DeployPhaseIamAndBedrock'
        'Invoke-DeployPhaseOrchestratorInfra'
        'Invoke-DeployPhaseCredentialIsolation'
        'Invoke-DeployPhaseDockerSecrets'
        'Invoke-DeployPhaseFleetDeploy'
    )
    PrivateData = @{ PSData = @{ } }
}
