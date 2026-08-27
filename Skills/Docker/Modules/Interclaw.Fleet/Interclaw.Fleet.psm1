#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Fleet -> SalmonRun.Fleet
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Fleet' 'SalmonRun.Fleet.ps1')).Path

Export-ModuleMember -Function * -Alias *
