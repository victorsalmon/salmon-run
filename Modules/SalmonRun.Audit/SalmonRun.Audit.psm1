#Requires -Version 7.0
Set-StrictMode -Off

. $PSScriptRoot\Private\audit-state.ps1

$__auditPrivatePath = Join-Path $PSScriptRoot 'Private'
if (Test-Path $__auditPrivatePath) {
    foreach ($f in Get-ChildItem -Path $__auditPrivatePath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}

$__auditPublicPath = Join-Path $PSScriptRoot 'Public'
if (Test-Path $__auditPublicPath) {
    foreach ($f in Get-ChildItem -Path $__auditPublicPath -Filter '*.ps1' -Recurse) {
        . $f.FullName
    }
}
