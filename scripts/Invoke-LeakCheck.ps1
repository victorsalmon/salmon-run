#Requires -Version 7.0
<#
.SYNOPSIS
    Scan the public package for private references that must not leak.
#>
[CmdletBinding()]
param(
    [string]$SearchRoot = ($PSScriptRoot | Split-Path -Parent)
)

$patterns = @(
    'C:\\Repos'
    'C:\\Users\\RDP'
    'worktree\.ca'
    'clocklobster'
    'ClockLobster'
    'Intersite'
    'anomalyco'
    'currents-bookkeeping|currentsbk\.ca'
    'INTERCLAW_.*_TOKEN'
    'ZOHO_BOOKS_ORG'
    'PLAID_ACCESS_TOKEN'
    'FLEET_API_TOKEN'
)

# The leak-check script itself and the canonical sync script contain the
# pattern list and scrub patterns, so they are excluded. The public package
# manifest (package.json) legitimately names the public repository origin.
$skip = @('Sync-FromCanonical.ps1', 'Invoke-LeakCheck.ps1')

$hits = Get-ChildItem -Path $SearchRoot -File -Recurse |
    Where-Object { $_.Name -notin $skip } |
    Select-String -Pattern $patterns -ErrorAction SilentlyContinue |
    Select-Object -Property Filename, LineNumber, Line, Pattern, Path

# package.json may legitimately reference the public worktree origin; ignore
# only the repository URL line, not other lines.
$hits = $hits | Where-Object {
    -not ($_.Filename -eq 'package.json' -and $_.Line -match '"url"')
}

if ($hits) {
    Write-Host "LEAKS FOUND:`n" -ForegroundColor Red
    $hits | ForEach-Object { Write-Host "$($_.Filename):$($_.LineNumber): $($_.Line)" }
    exit 1
}

Write-Host "No private references found." -ForegroundColor Green
