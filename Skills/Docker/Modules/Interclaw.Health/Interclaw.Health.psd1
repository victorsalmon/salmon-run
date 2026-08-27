@{
    RootModule = 'Interclaw.Health.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'c2111a42-86a6-4910-92f6-16942851b78f'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Copyright = '(c) Salmon Run. All rights reserved.'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Health.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Health')
    FunctionsToExport = @('*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
