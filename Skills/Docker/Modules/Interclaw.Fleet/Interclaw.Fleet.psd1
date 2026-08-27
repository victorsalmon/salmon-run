@{
    RootModule = 'Interclaw.Fleet.psm1'
    ModuleVersion = '1.0.0'
    GUID = '7a8c3c87-51cd-4d00-97ed-61df90495bb8'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Copyright = '(c) Salmon Run. All rights reserved.'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Fleet.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Fleet')
    FunctionsToExport = @('*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
