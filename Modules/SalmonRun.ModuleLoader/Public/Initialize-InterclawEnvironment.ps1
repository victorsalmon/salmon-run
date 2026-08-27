<#
.SYNOPSIS
    Bootstrap the Interclaw module environment: resolves repo root, configures PSModulePath, imports Core.
.DESCRIPTION
    Adds Modules to PSModulePath, imports SalmonRun.Core (which provides
    Import-InterclawModule and other core functions via transitive module loading),
    and returns the resolved repo root path. Safe to call multiple times — idempotent.
.PARAMETER RepoRoot
    Optional explicit repo root. If not provided, auto-detected by walking up from
    the module directory looking for AGENTS.md or .git sentinels.
.OUTPUTS
    System.String. The resolved repo root path.
.EXAMPLE
    Initialize-InterclawEnvironment
    Auto-detect repo root and bootstrap modules.
.EXAMPLE
    Initialize-InterclawEnvironment -RepoRoot "C:\Users\me\salmon-run"
    Bootstrap modules using an explicit repo root path.
.NOTES
    File: Initialize-InterclawEnvironment.ps1
    Requires: PowerShell 7.0+
    See-also: Import-InterclawModule
#>
function Initialize-InterclawEnvironment {
    [OutputType([string])]
    param(
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $current = $PSScriptRoot
        while ($current -and -not (
            (Test-Path (Join-Path $current "AGENTS.md") -PathType Leaf) -or
            (Test-Path (Join-Path $current ".git") -PathType Container)
        )) {
            $parent = Split-Path $current -Parent
            if ($parent -eq $current) { break }
            $current = $parent
        }
        $RepoRoot = $current
    }

    # All SalmonRun modules live under the single Modules/ root.
    $__moduleRoots = @(
        (Join-Path $RepoRoot "Modules")
    )
    foreach ($__root in $__moduleRoots) {
        if ($env:PSModulePath -notlike "*$__root*") {
            $env:PSModulePath = "$__root$([System.IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    if (-not (Get-Module SalmonRun.Core)) {
        $__ocCorePsd1 = Join-Path $__moduleRoots[0] "SalmonRun.Core" "SalmonRun.Core.psd1"
        Import-Module -Name $__ocCorePsd1 -Force -DisableNameChecking
    }

    return $RepoRoot
}
