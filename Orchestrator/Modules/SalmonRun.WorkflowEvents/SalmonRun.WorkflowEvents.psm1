#Requires -Version 7.0
Set-StrictMode -Off

$__publicPath = Join-Path $PSScriptRoot 'Public'
if (Test-Path $__publicPath) {
    Get-ChildItem -Path $__publicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

Export-ModuleMember -Function @(
    'Get-NamespaceLog',
    'Get-WorkflowEvents',
    'Write-NamespaceLog',
    'Write-WorkflowEvent'
)
