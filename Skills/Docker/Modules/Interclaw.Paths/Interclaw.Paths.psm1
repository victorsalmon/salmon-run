#Requires -Version 7.0
# Backward-compatibility shim for the Interclaw.Paths module name.
# Dot-sources the SalmonRun.Paths .ps1 wrapper, which loads the canonical .psm1.
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Paths' 'SalmonRun.Paths.ps1')).Path

Export-ModuleMember -Function * -Alias *
