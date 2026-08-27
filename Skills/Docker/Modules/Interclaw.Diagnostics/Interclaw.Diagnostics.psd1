# Boundary: Backward-compatibility shim for Interclaw.Diagnostics
@{
    RootModule = 'Interclaw.Diagnostics.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'f91aa44a-e9bb-43df-a986-6d46ef811cad'
    Author = 'Salmon Run'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Diagnostics functions under the legacy Interclaw.Diagnostics module name.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Diagnostics')
    FunctionsToExport = @('*')
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
