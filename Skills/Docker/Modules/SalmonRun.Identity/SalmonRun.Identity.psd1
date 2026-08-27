# Boundary: 'SalmonRun.Identity'
@{
    RootModule = 'SalmonRun.Identity.psm1'
    ModuleVersion = '1.0.0'
    GUID = '9fda82fc-9b59-4ac5-a9a8-082da598f68f'
    Author = 'Salmon Run'
    Description = 'Agent identity, sovereignty tier, coding-key availability, and resource naming for SalmonRun. Retains SalmonRun.Identity compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @(
        'SalmonRun.Config'
    )
    FunctionsToExport = @(
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
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}
