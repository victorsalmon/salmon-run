@{
    RootModule = 'SalmonRun.Git.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a2f4c8e1-6d3b-4e9a-bc7f-8d1e2f3a4b5c'
    Author               = 'Interclaw'
    Description          = 'GitHub token selection and management for Interclaw — separates read vs write tokens per ADR-0043'
    PowerShellVersion    = '7.0'
    RequiredModules      = @('SalmonRun.Core', 'SalmonRun.Config', 'SalmonRun.Process')
    FunctionsToExport    = @(
        'Get-GitHubToken'
        'Select-GitHubToken'
    )
    PrivateData = @{
        PSData = @{ }
    }
}
