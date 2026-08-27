#Requires -Version 7.0
# Backward-compatibility shim: $oldModuleName re-exports $newModuleName
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir '..\SalmonRun.DeployState\SalmonRun.DeployState.psm1') -Global -Force -DisableNameChecking