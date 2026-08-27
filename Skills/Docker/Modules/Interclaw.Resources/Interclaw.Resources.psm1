#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Resources -> SalmonRun.Resources
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Resources' 'SalmonRun.Resources.ps1')).Path

Export-ModuleMember -Function * -Alias *
