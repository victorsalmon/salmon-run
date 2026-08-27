<#
.SYNOPSIS
    Analyzes AQE model routing costs and tier efficiency.

.DESCRIPTION
    Queries the AQE bridge for routing economics data, displays tier efficiency, budget
    status, cost-per-quality metrics, and savings opportunities. Appends results to a
    local history file for trend analysis.
#>
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(0.0, 1.0)]
    [float]$TaskComplexity = 0.5
)

$ErrorActionPreference = "Stop"
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PSModulePath = "$__ocRepoRoot\Skills\Docker\Modules;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $__ocRepoRoot

Import-InterclawModule Core

$BridgeUrl = "http://mcp_aqe:21004"  # See Infrastructure/port-registry.json

# ==== HEADER DISPLAY ====
Write-Host "Model Cost Analysis (TaskComplexity: $TaskComplexity)" -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# ==== FETCH ROUTING ECONOMICS FROM BRIDGE ====
try {
    $Response = Invoke-RestMethod -Uri "${BridgeUrl}/tools/routing_economics" `
        -Method POST `
        -Body (@{ taskComplexity = $TaskComplexity } | ConvertTo-Json) `
        -ContentType "application/json" `
        -TimeoutSec 15
} catch {
    Write-SetupLog -Message "AQE bridge unreachable: $_" -Level ERROR
    exit 1
}

# ==== PARSE RESPONSE (handle wrapped vs direct format) ====
$Report = if ($Response.content) {
    $Response.content[0].text | ConvertFrom-Json
} else {
    $Response
}

# ==== DISPLAY TIER EFFICIENCY ====
Write-Host "`nTier Efficiency" -ForegroundColor Yellow
Write-Host "$($Report.tierEfficiency | Format-Table | Out-String)"

# ==== DISPLAY BUDGET STATUS ====
Write-Host "Budget Status" -ForegroundColor Yellow
Write-Host "$($Report.budgetStatus | Format-Table | Out-String)"

# ==== DISPLAY COST PER QUALITY ====
Write-Host "Cost Per Quality" -ForegroundColor Yellow
if ($Report.costPerQuality) {
    Write-Host "  Score: $($Report.costPerQuality.score)"
    Write-Host "  Trend: $($Report.costPerQuality.trend)"
}

# ==== DISPLAY SAVINGS OPPORTUNITIES ====
Write-Host "`nSavings Opportunities" -ForegroundColor Yellow
if ($Report.savingsOpportunities -and $Report.savingsOpportunities.Count -gt 0) {
    foreach ($Opp in $Report.savingsOpportunities) {
        Write-Host "  - [$($Opp.impact)] $($Opp.description) (saves $($Opp.estimatedSavings))" -ForegroundColor $(
            if ($Opp.impact -eq "high") { "Green" } elseif ($Opp.impact -eq "medium") { "Yellow" } else { "Gray" }
        )
    }
} else {
    Write-Host "  None identified" -ForegroundColor Gray
}

# ==== BUILD AND DISPLAY COST COMPARISON TABLE ====
Write-Host "`nCost Comparison (Markdown)" -ForegroundColor Yellow
if ($Report.tierEfficiency) {
    $Tiers = @($Report.tierEfficiency | ForEach-Object {
        if ($_.PSObject.Properties.Name -contains "tier") { $_ }
        else { $_ }
    })
    if ($Tiers.Count -gt 0) {
        Write-Host "| Tier | Cost/Request | Quality Score | Savings vs Next Tier |"
        Write-Host "|------|-------------|---------------|---------------------|"
        $SortedTiers = $Tiers | Sort-Object { $_.costPerRequest }
        for ($i = 0; $i -lt $SortedTiers.Count; $i++) {
            $T = $SortedTiers[$i]
            $Savings = if ($i -lt $SortedTiers.Count - 1) {
                $Next = $SortedTiers[$i + 1]
                $Diff = [float]$Next.costPerRequest - [float]$T.costPerRequest
                if ($Diff -gt 0) { "$($Diff.ToString('F4')) per request" } else { "—" }
            } else { "—" }
            Write-Host "| $($T.tier) | $($T.costPerRequest) | $($T.qualityScore) | $Savings |"
        }
    }
}

# ==== APPEND RESULT TO HISTORY FILE ====
$HistoryEntry = @{
    timestamp      = (Get-Date -Format "o")
    taskComplexity = $TaskComplexity
    report         = $Report
}
$ReportsDir = Get-ReportsDir
$HistoryFile = Join-Path $ReportsDir "model-cost-history.json"
$History = @()
if (Test-Path $HistoryFile) {
    try { $History = Get-Content -Path $HistoryFile -Raw | ConvertFrom-Json } catch { $History = @() }
    if ($History -isnot [array]) { $History = @($History) }
}
$History += $HistoryEntry
$History | ConvertTo-Json -Depth 4 | Out-File -FilePath $HistoryFile -Encoding utf8
Write-Host "`n  History appended: $HistoryFile" -ForegroundColor DarkGray

Write-Host "`n[OK] Cost analysis complete." -ForegroundColor Green
