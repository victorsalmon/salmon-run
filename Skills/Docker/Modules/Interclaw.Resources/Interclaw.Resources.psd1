@{
    RootModule = 'Interclaw.Resources.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'abbba818-9563-45c1-8254-2320c516670b'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Copyright = '(c) Salmon Run. All rights reserved.'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Resources.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Resources')
    FunctionsToExport = @('*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
