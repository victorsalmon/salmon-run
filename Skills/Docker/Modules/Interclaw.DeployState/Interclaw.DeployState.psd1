# Boundary: 'Interclaw.DeployState' compatibility shim
@{
    RootModule = 'Interclaw.DeployState.psm1'
    ModuleVersion = '1.0.0'
    GUID = '659faf22-c6a9-4215-aa5d-4a73d643bd67'
    Author = 'Salmon Run'
    Description = 'Backward-compatibility shim for $oldModuleName -> $newModuleName'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.DeployState')
    FunctionsToExport = @('*')
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}