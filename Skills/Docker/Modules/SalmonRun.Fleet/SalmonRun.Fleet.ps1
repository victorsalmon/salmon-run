#Requires -Version 7.0
# Thin wrapper around the canonical manifest so required SalmonRun modules load.
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir 'SalmonRun.Fleet.psd1') -Force -DisableNameChecking
