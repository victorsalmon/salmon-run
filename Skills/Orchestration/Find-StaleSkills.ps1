param(
    [switch]$ReportOnly
)

$registryPath = Join-Path $PSScriptRoot "..\..\Skills\skills.json"

if (-not (Test-Path $registryPath)) {
    Write-Error "skills.json not found at $registryPath"
    exit 1
}

$registry = Get-Content $registryPath -Raw | ConvertFrom-Json
$stale = $registry | Where-Object { $_.stale -eq $true }

if ($stale.Count -eq 0) {
    Write-Output "No stale skills found."
    return
}

Write-Output "=== Stale Skills Report ==="
Write-Output ""

foreach ($s in $stale) {
    Write-Output "SKILL: $($s.name)"
    Write-Output "  Path: $($s.path)"
    if ($s.superseded_by) {
        Write-Output "  Superseded by: $($s.superseded_by)"
        $supersededPath = Join-Path $PSScriptRoot "..\..\$($s.superseded_by)"
        $exists = Test-Path $supersededPath
        Write-Output "  Replacement exists: $exists"
    }
    Write-Output ""
}

Write-Output "Total stale: $($stale.Count)"

if (-not $ReportOnly) {
    Write-Host ""
    Write-Warning "These skills may need attention. Update skills.json to remove stale entries once confirmed."
}
