#Requires -Version 7.0
# Backward-compatibility shim for the Interclaw.Diagnostics module name.
# Dot-sources the SalmonRun.Diagnostics .ps1 wrapper, which loads the canonical .psm1.
$moduleDir = $PSScriptRoot
. (Resolve-Path (Join-Path $moduleDir '..' 'SalmonRun.Diagnostics' 'SalmonRun.Diagnostics.ps1')).Path

Export-ModuleMember -Function * -Alias *
