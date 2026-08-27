#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Identity -> SalmonRun.Identity
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Identity' 'SalmonRun.Identity.ps1')).Path

Export-ModuleMember -Function * -Alias *
