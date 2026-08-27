#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Health -> SalmonRun.Health
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Health' 'SalmonRun.Health.ps1')).Path

Export-ModuleMember -Function * -Alias *
