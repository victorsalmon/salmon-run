# Boundary: Backward-compatibility shim for Interclaw.Ports
@{
    RootModule = 'Interclaw.Ports.psm1'
    ModuleVersion = '1.0.0'
    GUID = '2b929179-3def-442f-9ef7-07512bba2853'
    Author = 'Salmon Run'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Ports functions under the legacy Interclaw.Ports module name.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Ports')
    FunctionsToExport = @('*')
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
