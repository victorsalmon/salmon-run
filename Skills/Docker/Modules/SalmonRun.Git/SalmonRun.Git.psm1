$script:ModuleRoot = $PSScriptRoot

Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' -Recurse | ForEach-Object {
    . $_.FullName
}

Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -Recurse | ForEach-Object {
    . $_.FullName
}

Export-ModuleMember -Function @(
    'Get-GitHubToken',
    'Select-GitHubToken'
)
