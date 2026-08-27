#Requires -Version 7.0
# Backward-compatibility shim for Interclaw.Images -> SalmonRun.Images
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Images' 'SalmonRun.Images.ps1')).Path

Export-ModuleMember -Function * -Alias *
