#Requires -Version 7.0
# Backward-compatibility shim: $oldModuleName re-exports $newModuleName
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir '..\SalmonRun.Git\SalmonRun.Git.psm1') -Global -Force -DisableNameChecking