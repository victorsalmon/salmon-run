<#
.SYNOPSIS
    Shared helper functions for the Interclaw setup scripts. Provides utility functions for logging, validation, and path resolution.
#>
# ==============================================================================
# Interclaw — 0Helpers.ps1 (DEPRECATED)
# ==============================================================================
# DEPRECATED: This file is no longer needed. Import modules directly
# in your script instead. This redirector will be removed in a future version.
# ==============================================================================

Write-Warning "0Helpers.ps1 is DEPRECATED. Import modules directly."
$modulesDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "Skills" "Docker" "Modules"
if ($env:PSModulePath -notlike "*$modulesDir*") {
    $env:PSModulePath = "$modulesDir;$env:PSModulePath"
}
Import-Module -Name (Join-Path $modulesDir "SalmonRun.Paths" "SalmonRun.Paths.psd1") -Force -DisableNameChecking
Import-Module -Name (Join-Path $modulesDir "SalmonRun.ModuleLoader" "SalmonRun.ModuleLoader.psd1") -Force -DisableNameChecking
Import-InterclawModule Core
