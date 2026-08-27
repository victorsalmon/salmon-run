#Requires -Version 7.0
$moduleDir = $PSScriptRoot
Import-Module (Join-Path $moduleDir '..\SalmonRun.Telegram\SalmonRun.Telegram.psm1') -Global -Force -DisableNameChecking