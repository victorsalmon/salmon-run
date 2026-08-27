# Boundary: No credentials — module loader
@{
    RootModule = 'SalmonRun.ModuleLoader.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'f013895d-dd26-4b45-9be7-2ab26f76f33d'
    Author = 'Salmon Run'
    Description = 'Interclaw module loader: caches module imports for fast subsequent use via Import-InterclawModule.'
    PowerShellVersion = '7.0'
    RequiredModules = @()
    FunctionsToExport = @('Import-InterclawModule', 'Initialize-InterclawEnvironment')
    PrivateData = @{ PSData = @{ } }
}
