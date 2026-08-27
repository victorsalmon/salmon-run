# Boundary: 'SalmonRun.Resources'
@{
    RootModule = 'SalmonRun.Resources.psm1'
    ModuleVersion = '1.0.0'
    GUID = '27480b96-8840-4cc7-aa05-5bb94edb1336'
    Author = 'Salmon Run'
    Description = 'Docker memory/disk profiling and fleet resource budget validation for SalmonRun. Retains SalmonRun.Resources compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @(
        'SalmonRun.Core',
        'SalmonRun.Diagnostics'
    )
    FunctionsToExport = @(
        'Measure-DockerResources',
        'Test-ResourceBudget'
    )
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ } }
}
