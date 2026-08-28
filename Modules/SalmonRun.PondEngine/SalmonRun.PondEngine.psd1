@{
    RootModule = 'SalmonRun.PondEngine.psm1'
    ModuleVersion = '0.1.5'
    GUID = 'f1c2a3b4-5c6d-7e8f-9a0b-1c2d3e4f5a6b'
    Author = 'Salmon Run'
    Description = 'Generalizable pond/workflow engine for salmon-run. Defines Pond classes, default pond configuration, and a task-pipeline dispatch engine.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Constants', 'SalmonRun.Paths')
    ScriptsToProcess = @('Classes/Pond.ps1')
    FunctionsToExport = @('Get-SalmonRunPonds', 'Start-PondEngine', 'New-PondStream', 'Get-PlanPondLog', 'Add-PlanPondLog', 'Get-SalmonRunPlanSchema')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}
