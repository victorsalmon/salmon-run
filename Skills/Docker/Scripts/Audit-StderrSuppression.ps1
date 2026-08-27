<#
.SYNOPSIS
    Audits Skills/Docker/ for 2>$null suppression patterns and categorizes occurrences.
.DESCRIPTION
    Scans all PowerShell files under Skills/Docker/ for 2>$null stderr suppression.
    Categorizes each occurrence as Tier 1 (safe: discovery/cleanup where failure is
    expected) or Tier 2 (risky: critical operations that should log warnings).
    Outputs a categorized report to the console.

    Run: .\Skills\Docker\Scripts\Audit-StderrSuppression.ps1 [-Path <dir>]
.PARAMETER Path
    Directory to scan. Defaults to Skills/Docker/.
#>
param(
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) "..")
)

$files = Get-ChildItem -Path $Path -Filter "*.ps1" -Recurse -File | Where-Object { $_.FullName -notmatch '(\\Tests\\|\\bin\\|\\obj\\)' }

$tier1Patterns = @(
    'docker\s+volume\s+ls',
    'docker\s+network\s+ls',
    'docker\s+service\s+ls',
    'docker\s+ps\s+',
    'docker\s+secret\s+ls',
    'docker\s+stack\s+services',
    'docker\s+info\s+',
    'docker\s+version\s+',
    'docker\s+image\s+inspect',
    'docker\s+node\s+ls',
    'docker\s+config\s+rm',
    'git\s+merge\s+--abort',
    'git\s+remote\s+get-url',
    'aws\s+sts\s+get-caller-identity',
    'aws\s+secretsmanager\s+get-secret-value',
    'tailscale\s+status',
    '2>\$null\s*\|\s*Select-Object\s+-First',
    '2>\$null\s*\|\s*Where-Object'
)

$tier2Patterns = @(
    'docker\s+volume\s+rm',
    'docker\s+network\s+rm',
    'docker\s+image\s+rm',
    'docker\s+rm\s+',
    'docker\s+service\s+update',
    'wsl\s+--shutdown',
    'docker\s+stack\s+rm'
)

$results = @()

foreach ($file in $files) {
    $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }
    $lines = $content -split "`r?`n"
    $lineNum = 0
    foreach ($line in $lines) {
        $lineNum++
        if ($line -notmatch '2>\$null') { continue }

        $isTier1 = $false
        $isTier2 = $false
        $matchedPattern = ""

        foreach ($p in $tier1Patterns) {
            if ($line -match $p) {
                $isTier1 = $true
                $matchedPattern = $p
                break
            }
        }

        if (-not $isTier1) {
            foreach ($p in $tier2Patterns) {
                if ($line -match $p) {
                    $isTier2 = $true
                    $matchedPattern = $p
                    break
                }
            }
        }

        $tier = if ($isTier1) { "Tier1" } elseif ($isTier2) { "TIER2" } else { "UNCAT" }
        $results += [pscustomobject]@{
            Tier    = $tier
            File    = $file.FullName
            Line    = $lineNum
            Content = $line.Trim()
        }
    }
}

$tier1Count = @($results | Where-Object { $_.Tier -eq "Tier1" }).Count
$tier2Count = @($results | Where-Object { $_.Tier -eq "TIER2" }).Count
$uncatCount = @($results | Where-Object { $_.Tier -eq "UNCAT" }).Count

Write-Host "`n=== Stderr Suppression Audit ===" -ForegroundColor Cyan
Write-Host "Total 2>`$null occurrences: $($results.Count)" -ForegroundColor White
Write-Host "  Tier 1 (safe):  $tier1Count" -ForegroundColor Green
Write-Host "  Tier 2 (risky): $tier2Count" -ForegroundColor Yellow
Write-Host "  Uncat:          $uncatCount" -ForegroundColor Gray

if ($tier2Count -gt 0) {
    Write-Host "`n--- Tier 2 (Risky) Locations ---" -ForegroundColor Yellow
    $results | Where-Object { $_.Tier -eq "TIER2" } | Sort-Object File, Line | ForEach-Object {
        $relPath = $_.File -replace [regex]::Escape($Path), ""
        Write-Host "  $relPath`:$($_.Line): $($_.Content)" -ForegroundColor Yellow
    }
}

if ($uncatCount -gt 0) {
    Write-Host "`n--- Uncategorized Locations ---" -ForegroundColor Gray
    $results | Where-Object { $_.Tier -eq "UNCAT" } | Sort-Object File, Line | ForEach-Object {
        $relPath = $_.File -replace [regex]::Escape($Path), ""
        Write-Host "  $relPath`:$($_.Line): $($_.Content)" -ForegroundColor Gray
    }
}

return $results
