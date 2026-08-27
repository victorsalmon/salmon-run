# Boundary: 'SalmonRun.Health'
@{
    RootModule = 'SalmonRun.Health.psm1'
    ModuleVersion = '1.0.0'
    GUID = '6bafc35d-9c3b-4fe0-bcf1-629007577805'
    Author = 'Salmon Run'
    Description = 'Fleet health check probes for SalmonRun. Retains SalmonRun.Health compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @(
        'SalmonRun.Core',
        'SalmonRun.Process'
    )
    FunctionsToExport = @(
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
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}
