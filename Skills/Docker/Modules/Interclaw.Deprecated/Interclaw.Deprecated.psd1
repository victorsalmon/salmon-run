# Boundary: No credentials — preserved CODE/WORK patterns (not imported by default)
@{
    RootModule = 'Interclaw.Deprecated.psm1'
    ModuleVersion = '1.0.0'
    GUID = '2826b4f8-6602-4bf1-b104-492ece30698c'
    Author = 'Interclaw'
    Description = 'Deprecated module preserving legacy Interclaw patterns'
    PowerShellVersion = '7.0'
    # Uses: Diagnostics (Write-SetupLog)
    RequiredModules   = @('SalmonRun.Core')
    FunctionsToExport = @(
        'Invoke-OpencodeWorkerImageBuild'
    )
    PrivateData = @{ PSData = @{ } }
}
