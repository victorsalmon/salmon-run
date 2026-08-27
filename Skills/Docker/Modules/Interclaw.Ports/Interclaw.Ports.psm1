#Requires -Version 7.0
# Backward-compatibility shim for the Interclaw.Ports module name.
# Dot-sources the SalmonRun.Ports .ps1 wrapper, which loads the canonical .psm1.
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Ports' 'SalmonRun.Ports.ps1')).Path

Export-ModuleMember -Function * -Alias *
