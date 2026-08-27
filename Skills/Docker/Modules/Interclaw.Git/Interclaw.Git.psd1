# Boundary: 'Interclaw.Git' compatibility shim
@{
    RootModule = 'Interclaw.Git.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'bab8e6f3-7f19-4a39-9692-67ef2bb1552a'
    Author = 'Salmon Run'
    Description = 'Backward-compatibility shim for $oldModuleName -> $newModuleName'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Git')
    FunctionsToExport = @('*')
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}