#Requires -Version 7.0
# Thin wrapper around canonical .psm1 loader
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir "Interclaw.Marketer.psm1") -Force -DisableNameChecking