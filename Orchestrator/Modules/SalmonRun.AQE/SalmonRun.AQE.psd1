@{
    RootModule           = 'SalmonRun.AQE.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '8b7c6d5e-4a3b-2c1d-0e9f-8a7b6c5d4e3f'
    Author               = 'Salmon Run'
    Description          = 'Public Agentic Quality Engineering (AQE) runner. Executes Pester, property tests, documentation lint, and an optional AQE bridge scan with graceful fallback.'
    PowerShellVersion    = '7.0'
    RequiredModules      = @('SalmonRun.Paths')
    FunctionsToExport    = @(
        'Invoke-SalmonRunAQE'
        'Invoke-SalmonRunAQEBridge'
        'Invoke-SalmonRunDocLint'
        'Invoke-SalmonRunPesterSuite'
    )
    AliasesToExport      = @()
    PrivateData = @{
        PSData = @{ }
    }
}
