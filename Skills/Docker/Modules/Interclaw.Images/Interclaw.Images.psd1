@{
    RootModule = 'Interclaw.Images.psm1'
    ModuleVersion = '1.0.0'
    GUID = '456bb454-c580-4551-9abf-659cbb299fea'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Copyright = '(c) Salmon Run. All rights reserved.'
    Description = 'Backward-compatibility shim that re-exports SalmonRun.Images.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Images')
    FunctionsToExport = @('*')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @('*')
    PrivateData = @{ PSData = @{ } }
}
