<#
.SYNOPSIS
    Build and publish the SalmonRun meta-module to the PowerShell Gallery.
.DESCRIPTION
    Validates the module manifest, then publishes the SalmonRun meta-module
    (and its bundled SalmonRun.* submodules) to the PowerShell Gallery using
    a NuGet API key resolved from the environment or a credential file.

    When no API key is available (or -WhatIf is set) the helper produces a
    local nupkg instead so the build is still evidenced.
.PARAMETER Repository
    Target PowerShell repository. Defaults to PSGallery.
.PARAMETER ApiKey
    NuGet API key for the PowerShell Gallery. Falls back to
    $env:POWERSHELL_GALLERY_KEY when not supplied.
.PARAMETER ModulePath
    Path to the SalmonRun module folder. Defaults to ./Modules/SalmonRun.
.PARAMETER LocalRepository
    Name of a local file-based repository to publish a nupkg into when no
    gallery key is available. Use this to produce a local artifact.
.PARAMETER WhatIf
    Validate the manifest and report the publish action without publishing.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Repository = 'PSGallery',
    [string]$ApiKey,
    [string]$ModulePath = (Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun'),
    [string]$LocalRepository,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$resolvedModule = Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop
Write-Host "Validating manifest: $resolvedModule" -ForegroundColor Cyan

Test-ModuleManifest -Path (Join-Path $resolvedModule.Path 'SalmonRun.psd1') -ErrorAction Stop
Write-Host 'Module manifest valid.' -ForegroundColor Green

$key = if ($ApiKey) { $ApiKey } { $env:POWERSHELL_GALLERY_KEY }

if ($WhatIf -or -not $key) {
    if ($LocalRepository) {
        Write-Host "No gallery key; publishing nupkg to local repository '$LocalRepository'." -ForegroundColor Yellow
        $target = Get-PSRepository -Name $LocalRepository -ErrorAction SilentlyContinue
        if (-not $target) {
            $localRoot = Join-Path $env:TEMP 'salmon-run-localrepo'
            $null = New-Item -ItemType Directory -Path $localRoot -Force
            Register-PSRepository -Name $LocalRepository -SourceLocation $localRoot -PublishLocation $localRoot -InstallationPolicy Trusted
        }
        if ($PSCmdlet.ShouldProcess($resolvedModule.Path, "Publish-Module to $LocalRepository")) {
            Publish-Module -Path $resolvedModule.Path -Repository $LocalRepository -Force
            Write-Host "Local nupkg published to repository '$LocalRepository'." -ForegroundColor Green
        }
    } else {
        Write-Host 'No gallery key supplied and no LocalRepository set; skipping publish (build validated only).' -ForegroundColor Yellow
    }
    return
}

if ($PSCmdlet.ShouldProcess($resolvedModule.Path, "Publish-Module to $Repository")) {
    Publish-Module -Path $resolvedModule.Path -Repository $Repository -NuGetApiKey $key -Force
    Write-Host "Published SalmonRun to $Repository." -ForegroundColor Green
}
