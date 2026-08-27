# Boundary: 'Interclaw.Deploy' compatibility shim
@{
    RootModule = 'Interclaw.Deploy.psm1'
    ModuleVersion = '1.0.0'
    GUID = '36eb0e80-5d4b-403d-9069-caf883093133'
    Author = 'Salmon Run'
    Description = 'Backward-compatibility shim for $oldModuleName -> $newModuleName'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Deploy')
    FunctionsToExport = @('*')
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}