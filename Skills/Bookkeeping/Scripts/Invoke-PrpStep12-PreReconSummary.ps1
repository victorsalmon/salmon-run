<#
.SYNOPSIS
    PRP Step 12: Pre-Reconciliation summary report — shows all processed
    periods with statement balances, Zoho balances, and notes.
.DESCRIPTION
    Generates a markdown summary of every period touched by the pipeline:
    period number, end date, statement closing balance, Zoho closing balance,
    and a notes column for discrepancies, posting lag, or other observations.
    This is the final deliverable — saved to Tasks/Logs/ and printed inline.
.PARAMETER DiscoveredPeriods
    PDF-backed period list from Step 4.
.PARAMETER ActivePeriods
    Active periods from Step 5 scope selection.
.PARAMETER SelectedScope
    Scope object from Step 5 (fiscal year label, mode).
.PARAMETER BalanceForwardResult
    Result object from Step 7 (contains PeriodStatus with diffs).
.PARAMETER ReconciliationResult
    Result object from Step 8 (contains reconciliation method/status).
.PARAMETER AuditWarningsResult
    Result object from Step 6 (contains warnings list).
.PARAMETER OrgName
    Organization name.
.PARAMETER AccountName
    Account slug name.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions (for balance computation).
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep12-PreReconSummary.ps1 -DiscoveredPeriods $periods -ActivePeriods $active -OrgName "intersite-consulting"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$DiscoveredPeriods,

    [Parameter()]
    [array]$ActivePeriods,

    [Parameter()]
    [PSCustomObject]$SelectedScope,

    [Parameter()]
    [PSCustomObject]$BalanceForwardResult,

    [Parameter()]
    [PSCustomObject]$ReconciliationResult,

    [Parameter()]
    [PSCustomObject]$AuditWarningsResult,

    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId
)

$ErrorActionPreference = "Stop"
$stepNumber = 12

if ($WhatIfPreference) {
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $true
        Details       = "WhatIf: summary generation skipped"
        SummaryPath   = $null
    }
}

$periodsForSummary = if ($ActivePeriods -and $ActivePeriods.Count -gt 0) { $ActivePeriods } else { $DiscoveredPeriods }
if (-not $periodsForSummary -or $periodsForSummary.Count -eq 0) {
    return [PSCustomObject]@{
        StepNumber  = $stepNumber
        Passed      = $false
        Details     = "No periods to summarize"
        SummaryPath = $null
    }
}

# Build balance lookup from ZohoAll
$zohoBalanceByPeriod = @{}
if ($ZohoAll -and $periodsForSummary) {
    $sortedPeriods = $periodsForSummary | ForEach-Object {
        $end = if ($_.period_end -is [datetime]) { $_.period_end } elseif ($_.end -is [datetime]) { $_.end } else {
            $parsed = $null; [datetime]::TryParse($_.period_end -or $_.end, [ref]$parsed) | Out-Null; $parsed
        }
        [PSCustomObject]@{ period_end = $end }
    } | Where-Object { $_.period_end } | Sort-Object period_end

    $runningBalance = 0
    $lastEnd = $null
    foreach ($p in $sortedPeriods) {
        $periodTxns = $ZohoAll | Where-Object {
            $d = if ($_.date -is [datetime]) { $_.date } else { $null; [datetime]::TryParse("$($_.date)", [ref]$null) | Out-Null; $null }
            $d -and $d -le $p.period_end -and (!$lastEnd -or $d -gt $lastEnd)
        }
        $net = 0
        foreach ($txn in $periodTxns) {
            $amt = [decimal]($txn.amount -or 0)
            $type = $txn.transaction_type -or $txn.debit_or_credit -or ""
            if ($type -eq "credit" -or $amt -lt 0) { $net -= [math]::Abs($amt) }
            else { $net += $amt }
        }
        $runningBalance = [math]::Round($runningBalance + $net, 2)
        $zohoBalanceByPeriod[$p.period_end.ToString('yyyy-MM-dd')] = $runningBalance
        $lastEnd = $p.period_end
    }
}

# Build balance forward diffs lookup
$bfDiffs = @{}
if ($BalanceForwardResult -and $BalanceForwardResult.PeriodStatus) {
    foreach ($kv in $BalanceForwardResult.PeriodStatus.GetEnumerator()) {
        $bfDiffs[$kv.Key] = $kv.Value.Diff
    }
}

# Build reconciliation status lookup
$reconStatus = @{}
if ($ReconciliationResult) {
    $reconStatus["method"] = $ReconciliationResult.Method -or "unknown"
    $reconStatus["verified"] = $ReconciliationResult.Verified -or $false
}

# Generate summary table
$lines = @(
    "# Pre-Reconciliation Summary: $OrgName — $AccountName",
    "",
    "**Run**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "**Scope**: $(if ($SelectedScope) { "FY$($SelectedScope.fiscal_year_label) ($($SelectedScope.mode))" } else { "All discovered periods" })",
    "**Overall pipeline**: $(if ($BalanceForwardResult -and $BalanceForwardResult.Passed) { 'PASSED' } else { 'HAS ISSUES' })",
    "",
    "| # | Period End | Statement Balance | Zoho Balance | Notes |",
    "|---|-----------|-----------------|-------------|-------|"
)

$periodNumber = 0
$warningsList = if ($AuditWarningsResult -and $AuditWarningsResult.Warnings) { $AuditWarningsResult.Warnings } else { @() }

$sortedPeriods = $periodsForSummary | ForEach-Object {
    $end = if ($_.period_end -is [datetime]) { $_.period_end } elseif ($_.end -is [datetime]) { $_.end } else {
        $parsed = $null; [datetime]::TryParse($_.period_end -or $_.end, [ref]$parsed) | Out-Null; $parsed
    }
    $close = if ($_.closing_balance) { [decimal]$_.closing_balance } else { 0 }
    [PSCustomObject]@{ period_end = $end; closing_balance = $close }
} | Where-Object { $_.period_end } | Sort-Object period_end

foreach ($p in $sortedPeriods) {
    $periodNumber++
    $label = $p.period_end.ToString('yyyy-MM-dd')
    $stmtBalance = $p.closing_balance
    $zohoBalance = $zohoBalanceByPeriod[$label]
    $bfDiff = $bfDiffs[$label]

    # Build notes
    $notes = @()

    # Check balance difference
    $stmtStr = $stmtBalance.ToString('C')
    $zohoStr = if ($null -ne $zohoBalance) { $zohoBalance.ToString('C') } else { "N/A" }

    if ($null -ne $bfDiff -and [math]::Abs($bfDiff) -gt 0) {
        if ([math]::Abs($bfDiff) -le 0.50) {
            $notes += "Posting lag or rounding: diff $($bfDiff.ToString('C'))"
        } else {
            $notes += "DISCREPANCY: diff $($bfDiff.ToString('C')) — needs investigation"
        }
    } elseif ($null -ne $bfDiff) {
        $notes += "Balanced"
    }

    # Check reconciliation status
    if ($reconStatus["verified"]) {
        $notes += "Reconciled ($($reconStatus['method']))"
    } else {
        $notes += "Not reconciled via pipeline"
    }

    # Check account-level warnings for this period
    $periodWarnings = $warningsList | Where-Object { $_.Detail -match [regex]::Escape($label) -or $_.Detail -match [regex]::Escape($p.period_end.ToString('yyyy-MM')) }
    if ($periodWarnings) {
        foreach ($w in $periodWarnings) { $notes += "Warning: $($w.Type)" }
    }

    $notesStr = if ($notes.Count -gt 0) { $notes -join "; " } else { "No issues" }

    $lines += "| $periodNumber | $label | $stmtStr | $zohoStr | $notesStr |"
}

# Summary totals row
$balancedCount = ($sortedPeriods | Where-Object {
    $label = $_.period_end.ToString('yyyy-MM-dd')
    $diff = $bfDiffs[$label]
    $null -eq $diff -or [math]::Abs($diff) -le 0.50
}).Count
$totalCount = $sortedPeriods.Count
$lines += ""
$lines += "**Summary**: $balancedCount / $totalCount periods balanced"

$reportContent = $lines -join "`n"

# Print inline
Write-Information "`n$reportContent`n" -Tags PRP

# Save to file
$logDir = Join-Path (Resolve-Path "$PSScriptRoot\..\..\..") "Tasks\Logs"
$null = New-Item -ItemType Directory -Path $logDir -Force
$reportPath = Join-Path $logDir "pre-recon-summary-$OrgName-$AccountName-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
$reportContent | Out-String | Set-Content -LiteralPath $reportPath -Encoding utf8

Write-Information "[PRP STEP 12] Pre-reconciliation summary saved to $reportPath" -Tags PRP

return [PSCustomObject]@{
    StepNumber  = $stepNumber
    Passed      = $true
    Details     = "Summary: $balancedCount/$totalCount periods balanced"
    SummaryPath = $reportPath
    SummaryText = $reportContent
}
