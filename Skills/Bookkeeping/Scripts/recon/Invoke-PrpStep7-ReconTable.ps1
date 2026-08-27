<#
.SYNOPSIS
    PRP Step 7: Generate canonical Reconciliation Table and append to report.
.DESCRIPTION
    Takes results from Steps 1 (sidecar), 2 (Zoho match), 5 (balance forward),
    and produces the canonical Reconciliation Table format defined in
    reconciliation-prep.md. Appends the table to the PRP report markdown file.
    Outputs to console as well.
.PARAMETER SidecarPeriods
    Array of period objects from Step 1.
.PARAMETER SidecarData
    Sidecar transaction data from Step 1.
.PARAMETER TasData
    TAS transaction data (parsed in pipeline).
.PARAMETER ZohoAll
    Bulk-fetched Zoho data from pipeline global state.
.PARAMETER BalanceForwardResults
    Result from Step 5 (has PeriodStatus).
.PARAMETER ZohoMatchResults
    Result from Step 2 (has PeriodResults).
.PARAMETER AccountName
    Account slug name.
.PARAMETER OrgName
    Organization name.
.PARAMETER IsCreditCard
    Whether this account is a credit card.
.PARAMETER ReportPath
    Path to the PRP report markdown file to append to.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$SidecarPeriods,

    [Parameter()]
    [array]$SidecarData,

    [Parameter()]
    [array]$TasData,

    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    $BalanceForwardResults,

    [Parameter()]
    $ZohoMatchResults,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [string]$OrgName,

    [bool]$IsCreditCard = $false,

    [string]$ReportPath = "",

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = 7
$stepName = "Reconciliation Table"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if (-not $SidecarPeriods -or $SidecarPeriods.Count -eq 0) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "No sidecar periods provided — cannot generate table"
        NextSteps  = @("Run Step 1 first")
    }
}

$periodStatus = if ($BalanceForwardResults -and $BalanceForwardResults.PeriodStatus) { $BalanceForwardResults.PeriodStatus } else { $null }
$zohoMatchResults = if ($ZohoMatchResults -and $ZohoMatchResults.PeriodResults) { $ZohoMatchResults.PeriodResults } else { $null }

# Compute per-period net flows
$tableLines = @()
$tableLines += "## $AccountName — Reconciliation Table"
$tableLines += ""
$tableLines += "| Period End | Opening | Credits | Debits | Net Flow | Closing | TAS Net | Zoho Net | Sidecar vs TAS | Sidecar vs Zoho | Status |"
$tableLines += "|------------|---------|---------|--------|----------|---------|---------|----------|----------------|-----------------|--------|"

$prevEnd = $null
$opening = $null
$allPassed = $true

for ($i = 0; $i -lt $SidecarPeriods.Count; $i++) {
    $p = $SidecarPeriods[$i]
    $startDate = if ($p.start -is [datetime]) { $p.start.ToString('yyyy-MM-dd') } else { $p.start }
    $endDate = if ($p.end -is [datetime]) { $p.end.ToString('yyyy-MM-dd') } else { $p.end }

    # Get sidecar transactions for this period
    $periodSc = if ($SidecarData) {
        $SidecarData | Where-Object {
            $d = if ($_.date -is [datetime]) { $_.date.ToString('yyyy-MM-dd') } else { $_.date }
            $d -ge $startDate -and $d -le $endDate
        }
    } else { @() }

    $scCredits = [math]::Round(($periodSc | Where-Object { $_.type -eq "credit" } | Measure-Object amount -Sum).Sum, 2)
    $scDebits = [math]::Round(($periodSc | Where-Object { $_.type -eq "debit" } | Measure-Object amount -Sum).Sum, 2)
    if (-not $scCredits) { $scCredits = 0 }
    if (-not $scDebits) { $scDebits = 0 }
    $sidecarNet = [math]::Round($scCredits - $scDebits, 2)

    # Get TAS transactions for this period
    $periodTas = if ($TasData) {
        $TasData | Where-Object { $_.date -ge $startDate -and $_.date -le $endDate }
    } else { @() }
    $tasNet = [math]::Round(($periodTas | Measure-Object amount -Sum).Sum, 2)
    if (-not $tasNet) { $tasNet = 0 }

    # Get Zoho transactions for this period (with tolerance)
    $periodZoho = if ($ZohoAll) {
        $ZohoAll | Where-Object {
            try {
                $zd = [datetime]::ParseExact($_.date.Trim(), 'yyyy-MM-dd', $null)
                $pStart = if ($p.start -is [datetime]) { $p.start } else { [datetime]::ParseExact($startDate, 'yyyy-MM-dd', $null) }
                $pEnd = if ($p.end -is [datetime]) { $p.end } else { [datetime]::ParseExact($endDate, 'yyyy-MM-dd', $null) }
                $zd -ge $pStart.AddDays(-2) -and $zd -le $pEnd.AddDays(2)
            } catch { $false }
        }
    } else { @() }
    $zohoNet = [math]::Round(($periodZoho | Where-Object { $_.amount -ne $null } | Measure-Object amount -Sum).Sum, 2)
    if (-not $zohoNet) { $zohoNet = 0 }

    # Balance forward
    if ($i -eq 0) {
        if ($IsCreditCard) {
            $opening = [math]::Round($p.closing_balance + $sidecarNet, 2)
        } else {
            $opening = [math]::Round($p.closing_balance - $sidecarNet, 2)
        }
    }
    $closing = if ($IsCreditCard) {
        [math]::Round($opening - $sidecarNet, 2)
    } else {
        [math]::Round($opening + $sidecarNet, 2)
    }

    $scVsTas = [math]::Abs($sidecarNet - $tasNet)
    $scVsZoho = [math]::Abs($sidecarNet - $zohoNet)

    $flowOk = $scVsTas -le 0.50 -and $scVsZoho -le 0.50
    $balanceOk = [math]::Abs([math]::Round($p.closing_balance - $closing, 2)) -le 0.01
    $periodOk = $flowOk -and $balanceOk
    if (-not $periodOk) { $allPassed = $false }

    $statusEmoji = if ($periodOk) { "✅" } else { "❌" }
    $scVsTasStr = if ($scVsTas -le 0.02) { "✅ $scVsTas" } else { "⚠ $scVsTas" }
    $scVsZohoStr = if ($scVsZoho -le 0.50) { "✅ $scVsZoho" } else { "❌ $scVsZoho" }

    $tableLines += "| $endDate | $opening | $scCredits | $scDebits | $sidecarNet | $($p.closing_balance) | $tasNet | $zohoNet | $scVsTasStr | $scVsZohoStr | $statusEmoji |"

    $opening = $p.closing_balance
}

$tableLines += ""
$tableLines += "**Overall**: $(if ($allPassed) { '✅ All periods pass' } else { '❌ Some periods have discrepancies' })"
$tableLines += ""

# Output to console
Write-Information "`n=== $AccountName Reconciliation Table ===" -Tags PRP
foreach ($line in $tableLines) { Write-Information $line -Tags PRP }

# Append to report file
if ($ReportPath -and (Test-Path $ReportPath)) {
    try {
        $existing = Get-Content $ReportPath -Raw
        $tableContent = ($tableLines -join "`n") + "`n"
        $existing + "`n" + $tableContent | Set-Content -LiteralPath $ReportPath -Encoding utf8
        Write-Information "[PRP STEP 7] Reconciliation Table appended to $ReportPath" -Tags PRP
    } catch {
        Write-Warning "[PRP STEP 7] Could not append to report: $_"
    }
} else {
    Write-Information "[PRP STEP 7] No report path provided — table output to console only" -Tags PRP
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber = $stepNumber
    Passed     = $allPassed
    Details    = "Reconciliation Table generated: $($SidecarPeriods.Count) periods, $(if ($allPassed) { 'all pass' } else { 'some have discrepancies' })"
    TableLines = $tableLines
    NextSteps  = @(
        "The Reconciliation Table is now part of the PRP report",
        "Review any ❌ periods and fix transactions before proceeding"
    )
}
