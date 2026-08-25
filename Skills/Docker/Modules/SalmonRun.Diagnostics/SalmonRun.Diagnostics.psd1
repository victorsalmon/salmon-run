# Boundary: No credentials — logging helpers
@{
    RootModule = 'SalmonRun.Diagnostics.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a3f9c2b1-8d7e-4f5a-9c1d-6e8b7a4c5d2f'
    Author = 'Salmon Run'
    Description = 'Logging, test-step recording, and report-deliverables directory resolution for SalmonRun.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Paths')
    FunctionsToExport = @('Write-SetupLog','Test-Step','Get-ReportsDir','Get-DeliverablesDir')
    PrivateData = @{ PSData = @{ } }
}
