#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot

. $PSScriptRoot\Private\web-state.ps1

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
    'Get-WebSecretBundle',
    'Invoke-WebSearch'
)

$HandlerPaths = @(
    (Join-Path $script:ModuleRoot 'Handlers/Drive/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Email/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Search/*.ps1')
)
foreach ($pattern in $HandlerPaths) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        . $_.FullName
    }
}
