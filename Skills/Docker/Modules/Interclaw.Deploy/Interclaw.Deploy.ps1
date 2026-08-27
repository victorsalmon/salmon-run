#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Deploy -> SalmonRun.Deploy
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir 'SalmonRun.Deploy.psm1') -Force -DisableNameChecking