# Boundary: credential and .env resolution. No credential values are stored here.
@{
    RootModule           = 'SalmonRun.Credentials.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '7c9e1a8d-5b4f-4e2c-9d3e-1f2a3b4c5d6e'
    Author               = 'Salmon Run'
    Description          = 'Modular credential resolution for Salmon Run agents. Reads ~/.salmon/.env and resolves values from AWS, GitHub, Worktree, files, or environment variables.'
    PowerShellVersion    = '7.0'
    RequiredModules      = @('SalmonRun.Core')
    FunctionsToExport    = @(
        'Get-SalmonRunCredential'
        'Get-SalmonRunEnvFile'
        'Register-SalmonRunCredentialResolver'
        'Resolve-SalmonRunCredentialValue'
    )
    AliasesToExport      = @()
    PrivateData = @{
        PSData = @{ }
    }
}
