<#
.SYNOPSIS
    Configuration values, install environment, fleet config, workspace repos, env-file loading, and schema validation for SalmonRun.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot

$PrivatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $PrivatePath) {
    foreach ($f in Get-ChildItem -Path $PrivatePath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}
$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    foreach ($f in Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}

Export-ModuleMember -Function @(
    'Export-InstallJsonToEnv',
    'Find-InstallJsonPath',
    'Get-ConfigValue',
    'Get-DefaultDomainSuffix',
    'Get-DefaultProjectCode',
    'Get-OwnerPlaceholders',
    'Get-SilentToggle',
    'Read-InstallJson',
    'Resolve-FleetConfig',
    'Resolve-StringPlaceholders',
    'Set-InstallJsonOverride',
    'Set-OwnerPlaceholders',
    'Test-SalmonRunConfigSchema',
    'Update-InstallJsonKey',
    'Update-InstallJsonTestStatus'
)

# Backward-compatibility alias for the previous Interclaw-prefixed schema validator
Set-Alias -Name 'Test-InterclawConfigSchema' -Value 'Test-SalmonRunConfigSchema'
Export-ModuleMember -Alias 'Test-InterclawConfigSchema'
