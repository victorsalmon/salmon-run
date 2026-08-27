<#
.SYNOPSIS
    Fleet resource preflight for SalmonRun.
#>
#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot
$PrivatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $PrivatePath) {
    Get-ChildItem -Path $PrivatePath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'Measure-DockerResources',
    'Test-ResourceBudget'
)
