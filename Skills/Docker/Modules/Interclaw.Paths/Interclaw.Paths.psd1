# Boundary: Backward-compatibility shim for Interclaw.Paths
@{
    RootModule = 'Interclaw.Paths.psm1'
    ModuleVersion = '1.0.0'
    GUID = '8a4b3c2d-1e5f-4a7b-9c3d-2e8f1a6b4c7e'
    Author = 'Salmon Run'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Paths functions under the legacy Interclaw.Paths module name.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Paths')
    FunctionsToExport = @('*')
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
