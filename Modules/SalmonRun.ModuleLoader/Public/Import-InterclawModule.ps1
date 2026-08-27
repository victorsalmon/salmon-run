<#
.SYNOPSIS
    Imports a SalmonRun module by name, discovering it from the Modules directory.
.DESCRIPTION
    Resolves the module path under Modules/SalmonRun.<Name> and
    imports via the .psd1 manifest if found, falling back to the legacy
    Modules/Interclaw.<Name> shim when the canonical module does not
    exist. Dot-sources the .ps1 file as a last resort. Appends the Modules
    directory to PSModulePath if not already present. Throws if neither file exists.
.PARAMETER Name
    The module name segment after SalmonRun. (e.g. "Core", "Config", "Deploy").
.OUTPUTS
    None. The module functions are imported into the Global scope.
#>
function Import-InterclawModule {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$ModulesDir
    )
    $moduleName = "SalmonRun.$Name"
    $legacyModuleName = "Interclaw.$Name"

    # Resolve module roots: an explicit -ModulesDir wins; otherwise search the
    # single Modules/ root.
    $moduleRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($ModulesDir)) {
        $moduleRoots = @($ModulesDir)
    } else {
        $repoRoot = Get-InterclawRepoRoot
        $moduleRoots = @(
            (Join-Path $repoRoot "Modules")
        )
    }

    foreach ($__root in $moduleRoots) {
        if ($env:PSModulePath -notlike "*$__root*") {
            $env:PSModulePath = "$__root$([System.IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    $moduleDir = $null
    foreach ($__root in $moduleRoots) {
        $__candidate = Join-Path $__root $moduleName
        if (Test-Path $__candidate) { $moduleDir = $__candidate; break }
        $__legacyCandidate = Join-Path $__root $legacyModuleName
        if (Test-Path $__legacyCandidate) { $moduleDir = $__legacyCandidate; break }
    }
    if (-not $moduleDir) {
        throw "Module $moduleName (or legacy $legacyModuleName) not found under: $($moduleRoots -join ', ')"
    }

    # The on-disk manifest name must match the directory name we found.
    $resolvedName = Split-Path -Leaf $moduleDir
    $psd1 = Join-Path $moduleDir "$resolvedName.psd1"
    if (Test-Path $psd1) {
        Import-Module -Name $psd1 -Force -DisableNameChecking -Scope Global
    } else {
        $ps1 = Join-Path $moduleDir "$resolvedName.ps1"
        if (Test-Path $ps1) {
            . $ps1
        } else {
            throw "Module $resolvedName not found at $moduleDir"
        }
    }
}
