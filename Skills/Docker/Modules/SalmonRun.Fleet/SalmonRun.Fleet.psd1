# Boundary: 'SalmonRun.Fleet'
@{
    RootModule = 'SalmonRun.Fleet.psm1'
    ModuleVersion = '1.0.0'
    GUID = '25c604d8-eac3-4927-b460-ce4671be3f80'
    Author = 'Salmon Run'
    Description = 'Fleet health checks, auto-remediation, and startup verification for SalmonRun. Retains SalmonRun.Fleet compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @(
        'SalmonRun.Core',
        'SalmonRun.Config',
        'SalmonRun.Diagnostics',
        'SalmonRun.Identity',
        'SalmonRun.Secrets',
        'SalmonRun.Process',
        'SalmonRun.Ports',
        'SalmonRun.Health'
    )
    FunctionsToExport = @(
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
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}
