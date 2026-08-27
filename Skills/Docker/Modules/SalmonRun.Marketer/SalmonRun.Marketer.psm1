#Requires -Version 7.0

Set-StrictMode -Off

$script:ModuleRoot = $PSScriptRoot

. $PSScriptRoot\Private\marketer-state.ps1

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
    'Get-MarketerSecretBundle'
)

$HandlerPaths = @(
    (Join-Path $script:ModuleRoot 'Handlers/Attio/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Hunter/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Smartlead/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Onboarding/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Analysis/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Apollo/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/ZeroBounce/*.ps1')
)
foreach ($pattern in $HandlerPaths) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        . $_.FullName
    }
}

Initialize-MarketerSecrets