#Requires -Version 7.0
<#
.SYNOPSIS
    File and namespace locking primitives for Interclaw.
.DESCRIPTION
    Provides Lock-File, Unlock-File, Register-Namespace, Remove-NamespaceReservation
    and related aliases, plus private lock-state tracking and deadlock detection.
    Extracted from SalmonRun.Core to separate locking concerns from core utilities.
#>

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot

# Note: Get-InterclawConstants (from SalmonRun.Constants) is used by Register-Namespace.
# It is NOT imported here — PowerShell auto-loading resolves it at runtime.
# Tests using Register-Namespace directly should stub Get-InterclawConstants in BeforeAll.

# Source Private/*.ps1 files (internal helpers)
$__privatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $__privatePath) {
    foreach ($f in Get-ChildItem -Path $__privatePath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}

# Source Public/*.ps1 files
$__publicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $__publicPath) {
    foreach ($f in Get-ChildItem -Path $__publicPath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}

# Backward-compat aliases
Set-Alias -Name 'Acquire-FileLock' -Value 'Lock-File'
Set-Alias -Name 'Release-FileLock' -Value 'Unlock-File'
Set-Alias -Name 'Acquire-NamespaceReservation' -Value 'Register-Namespace'
Set-Alias -Name 'Reserve-Namespace' -Value 'Register-Namespace'
Set-Alias -Name 'Release-NamespaceReservation' -Value 'Remove-NamespaceReservation'
