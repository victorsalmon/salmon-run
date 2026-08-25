# Boundary: No credentials — config values, install.json schema
@{
    RootModule = 'SalmonRun.Config.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '1d23b4ff-4e36-45b0-8d73-cfe0ac78fc73'
    Author               = 'Salmon Run'
    Description          = 'Configuration resolution module for SalmonRun fleet management. Retains SalmonRun.Config compatibility aliases.'
    PowerShellVersion    = '7.0'
    # Uses: Core (Write-AtomicJson), Paths (Get-SalmonRunRepoRoot), Diagnostics (Write-SetupLog)
    RequiredModules      = @('SalmonRun.Core')
    FunctionsToExport    = @(
        'Export-InstallJsonToEnv'
        'Get-ConfigValue'
        'Get-DefaultDomainSuffix'
        'Get-DefaultProjectCode'
        'Get-OwnerPlaceholders'
        'Get-SilentToggle'
        'Read-InstallJson'
        'Resolve-FleetConfig'
        'Resolve-StringPlaceholders'
        'Set-OwnerPlaceholders'
        'Set-InstallJsonOverride'
        'Test-SalmonRunConfigSchema'
        'Update-InstallJsonKey'
        'Update-InstallJsonTestStatus'
        'Find-InstallJsonPath'
    )
    AliasesToExport      = @(
        'Test-InterclawConfigSchema'
    )
    PrivateData = @{
        PSData = @{ }
    }
}
