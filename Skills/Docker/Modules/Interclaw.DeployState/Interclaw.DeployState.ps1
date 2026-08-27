#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.DeployState -> SalmonRun.DeployState
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir 'SalmonRun.DeployState.psm1') -Force -DisableNameChecking