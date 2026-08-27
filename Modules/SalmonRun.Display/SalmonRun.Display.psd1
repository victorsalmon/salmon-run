# Boundary: No credentials — parallel-section rendering helpers
@{
    RootModule = 'SalmonRun.Display.psm1'
    ModuleVersion = '1.0.0'
    GUID = '3d40cf67-dd6d-4474-92c8-b3283e757ec6'
    Author = 'Salmon Run'
    Description = 'Parallel section header/summary display helpers for Salmon Run setup output.'
    PowerShellVersion = '7.0'
    RequiredModules = @()
    FunctionsToExport = @('Write-ParallelSectionHeader','Write-ParallelSectionSummary')
    PrivateData = @{ PSData = @{ } }
}
