#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Git -> SalmonRun.Git
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir 'SalmonRun.Git.psm1') -Force -DisableNameChecking