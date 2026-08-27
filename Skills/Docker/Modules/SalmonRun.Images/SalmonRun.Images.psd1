# Boundary: 'SalmonRun.Images'
@{
    RootModule = 'SalmonRun.Images.psm1'
    ModuleVersion = '1.0.0'
    GUID = '271bde1e-9087-4c2b-9092-19a98f7933e0'
    Author = 'Salmon Run'
    Description = 'Docker image build orchestration for SalmonRun fleet services. Retains SalmonRun.Images compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @(
        'SalmonRun.Core',
        'SalmonRun.Diagnostics',
        'SalmonRun.Process'
    )
    FunctionsToExport = @(
        'Invoke-FleetImageBuild',
        'Invoke-OpencodeImageBuild',
        'Invoke-BookkeepingImageBuild',
        'Invoke-McpBrowserlessImageBuild',
        'Invoke-DocusignImageBuild',
        'Invoke-FunnelProxyImageBuild',
        'Invoke-MarketerImageBuild',
        'Invoke-MonitoringImageBuild',
        'Start-ParallelImageBuild',
        'Invoke-HermesImageBuild'
    )
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}
