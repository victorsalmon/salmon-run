@{
    RootModule = 'Interclaw.Identity.psm1'
    ModuleVersion = '1.0.0'
    GUID = '573274f7-0491-4207-bfaa-ebad703c2335'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Copyright = '(c) Salmon Run. All rights reserved.'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Identity.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Identity')
    FunctionsToExport = @('*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
