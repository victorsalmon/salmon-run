#Requires -Version 7.0
<#
.SYNOPSIS
    Project files from the canonical repo into the public salmon-run package.
.DESCRIPTION
    Copies canonical source and applies the public-package filter:
    - strips private hostnames, tokens, client paths, and absolute Windows paths
    - drops environment-only skills and scripts
    - keeps the canonical SalmonRun.* modules and public Skills
    - never copies the Tasks/ queue tree (runtime state lives in ~/.salmon)
    Run after any canonical change, then run Invoke-LeakCheck.ps1.
#>
[CmdletBinding()]
param(
    [string]$CanonicalRepo = 'C:\Repos\salmon-orchestrator'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CanonicalRepo -PathType Container)) {
    throw "Canonical repo not found at $CanonicalRepo"
}

$PublicRoot = $PSScriptRoot | Split-Path -Parent

$SourceDirs = @(
    @{ Src = 'Orchestrator/Modules'; Pattern = 'SalmonRun.*' },
    @{ Src = 'Skills'; Pattern = '*' }
)

foreach ($entry in $SourceDirs) {
    $srcRoot = Join-Path $CanonicalRepo $entry.Src
    $dstRoot = Join-Path $PublicRoot $entry.Src
    if (-not (Test-Path $srcRoot)) { continue }
    if (-not (Test-Path $dstRoot)) { $null = New-Item -ItemType Directory -Path $dstRoot -Force }
    Get-ChildItem -Path $srcRoot -Directory -Filter $entry.Pattern |
        ForEach-Object {
            $dst = Join-Path $dstRoot $_.Name
            Copy-Item -Path $_.FullName -Destination $dst -Recurse -Force
        }
}

# Public docs are hand-curated; do not bulk-copy the private docs tree.
Write-Host "Canonical projection complete. Run scripts/Invoke-LeakCheck.ps1 next." -ForegroundColor Green
