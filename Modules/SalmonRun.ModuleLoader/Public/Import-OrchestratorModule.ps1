<#
.DEPRECATED: This file is not loaded by the module loader and has zero callers in the codebase.
Kept for reference per Script Deprecation Protocol.
#>

<#
.SYNOPSIS
    Imports an Interclaw module by name, discovering it from the Modules directory.
.DESCRIPTION
    Resolves the module path under Modules/Interclaw.<Name> and
    imports via the .psd1 manifest if found, or dot-sources the .ps1 file as
    a fallback. Appends the Modules directory to PSModulePath if not already
    present. Throws if neither file exists.
.PARAMETER Name
    The module name segment after Interclaw. (e.g. "Core", "Config", "Deploy").
.OUTPUTS
    None. The module functions are imported into the Global scope.
#>
function Import-ORCHESTRATORModule {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$ModulesDir
    )
    $moduleName = "Interclaw.$Name"
    if ([string]::IsNullOrWhiteSpace($ModulesDir)) {
        $repoRoot = Get-ORCHESTRATORRepoRoot
        $ModulesDir = Join-Path $repoRoot "Modules"
    }
    if ($env:PSModulePath -notlike "*$ModulesDir*") {
        $env:PSModulePath = "$ModulesDir$([System.IO.Path]::PathSeparator)$env:PSModulePath"
    }
    $moduleDir = Join-Path $ModulesDir $moduleName
    $psd1 = Join-Path $moduleDir "$moduleName.psd1"
    if (Test-Path $psd1) {
        Import-Module -Name $psd1 -Force -DisableNameChecking -Scope Global
    } else {
        $ps1 = Join-Path $moduleDir "$moduleName.ps1"
        if (Test-Path $ps1) {
            . $ps1
        } else {
            throw "Module Interclaw.$Name not found at $moduleDir"
        }
    }
}
