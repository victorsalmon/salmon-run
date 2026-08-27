#Requires -Version 7.0

Set-StrictMode -Version 3.0

$script:ModuleRoot = $PSScriptRoot

# Load classes first so public/private functions can type-reference them.
$classPath = Join-Path $script:ModuleRoot 'Classes/Pond.ps1'
if (Test-Path -LiteralPath $classPath) {
    . $classPath
}

# Private functions and task implementations
$privatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path -LiteralPath $privatePath) {
    foreach ($f in Get-ChildItem -Path "$privatePath\*.ps1" -Recurse -ErrorAction SilentlyContinue) {
        . $f.FullName
    }
}

# Public functions
$publicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path -LiteralPath $publicPath) {
    foreach ($f in Get-ChildItem -Path "$publicPath\*.ps1" -ErrorAction SilentlyContinue) {
        . $f.FullName
    }
}
