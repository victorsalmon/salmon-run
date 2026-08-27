<#
.SYNOPSIS
    Modular credential resolution for Salmon Run agents.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
$script:CredentialResolvers = @{}

$PrivatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $PrivatePath) {
    foreach ($f in Get-ChildItem -Path $PrivatePath -Filter '*.ps1' -File -Recurse) {
        . $f.FullName
    }
}

$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    foreach ($f in Get-ChildItem -Path $PublicPath -Filter '*.ps1' -File -Recurse) {
        . $f.FullName
    }
}

Export-ModuleMember -Function @(
    'Get-SalmonRunCredential',
    'Get-SalmonRunEnvFile',
    'Register-SalmonRunCredentialResolver',
    'Resolve-SalmonRunCredentialValue'
)

Register-DefaultSalmonRunCredentialResolvers
