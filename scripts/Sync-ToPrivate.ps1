#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PublicRepo = (Split-Path $PSScriptRoot -Parent),
    [string]$PrivateRepo = $env:SALMON_PRIVATE_REPO,
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'public-to-private.manifest.json'),
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PrivateRepo)) { throw 'Provide -PrivateRepo or set SALMON_PRIVATE_REPO.' }
foreach ($path in @($PublicRepo, $PrivateRepo)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Repository directory not found: $path" }
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Sync manifest not found: $ManifestPath" }

$publicRoot = [IO.Path]::GetFullPath($PublicRepo).TrimEnd('\','/')
$privateRoot = [IO.Path]::GetFullPath($PrivateRepo).TrimEnd('\','/')
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 20
if ([int]$manifest.schemaVersion -ne 1 -or $manifest.direction -ne 'public-to-private') { throw 'Unsupported or incorrectly directed sync manifest.' }

foreach ($entry in @($manifest.entries)) {
    $source = [IO.Path]::GetFullPath((Join-Path $publicRoot $entry.source))
    $target = [IO.Path]::GetFullPath((Join-Path $privateRoot $entry.target))
    if (-not $source.StartsWith("$publicRoot\", [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest source escapes public repository: $($entry.source)" }
    if (-not $target.StartsWith("$privateRoot\", [StringComparison]::OrdinalIgnoreCase)) { throw "Manifest target escapes private repository: $($entry.target)" }
    foreach ($protected in @($manifest.protectedPrivatePaths)) {
        $protectedRoot = [IO.Path]::GetFullPath((Join-Path $privateRoot $protected)).TrimEnd('\','/')
        if ($target -eq $protectedRoot -or $target.StartsWith("$protectedRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Manifest target is protected private state: $($entry.target)"
        }
    }
    if (-not (Test-Path -LiteralPath $source)) { throw "Manifest source is missing: $($entry.source)" }

    if (Test-Path -LiteralPath $source -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($target, "Copy canonical public file '$($entry.source)'")) {
            $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
            Copy-Item -LiteralPath $source -Destination $target -Force
        }
        continue
    }
    foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
        $relative = $file.FullName.Substring($source.Length).TrimStart('\','/')
        $destination = Join-Path $target $relative
        if ($PSCmdlet.ShouldProcess($destination, "Copy canonical public file '$relative'")) {
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        }
    }
}

if ($Verify -and -not $WhatIfPreference) {
    & (Join-Path $PSScriptRoot 'Test-PrivateParity.ps1') -PublicRepo $publicRoot -PrivateRepo $privateRoot -ManifestPath $ManifestPath
}
Write-Output 'SALMON_PUBLIC_TO_PRIVATE_SYNC_PASS'
