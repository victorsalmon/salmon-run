<#
.SYNOPSIS
    PRP Step 7: Balance forward verification using recon-troubleshoot.
.DESCRIPTION
    Evaluates whether Zoho balance at each PDF statement end date matches
    the statement's closing balance. Only PDF-backed periods (from Step 4)
    are evaluated. Transactions after each statement end date are excluded.
    Ground truth = PDF statement closing balance (not three-way comparison).
.PARAMETER TasWorkingPath
    Path to session-scoped working TAS CSV from Step 2.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions array.
.PARAMETER DiscoveredPeriods
    PDF-backed period list from Step 4.
.PARAMETER ActivePeriods
    Active periods from Step 5 scope selection.
.PARAMETER AmountTolerance
    Dollar tolerance for balance comparison (default: 0.50).
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep7-BalanceForward.ps1 -TasWorkingPath $path -ZohoAll $zohoAll -DiscoveredPeriods $periods -ActivePeriods $active
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$TasWorkingPath,

    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [array]$DiscoveredPeriods,

    [Parameter()]
    [array]$ActivePeriods,

    [decimal]$AmountTolerance = 0.50,

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
$stepNumber = 7
$stepName = "Balance Forward Verification (recon-troubleshoot)"
$troubleshootLogDir = Join-Path (Resolve-Path "$PSScriptRoot\..\..\..") "Tasks\Logs"

Write-Progress -Activity "[PRP Step 7]" -Status $stepName

$periodsToCheck = if ($ActivePeriods -and $ActivePeriods.Count -gt 0) { $ActivePeriods } else { $DiscoveredPeriods }

if (-not $periodsToCheck -or $periodsToCheck.Count -eq 0) {
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $false
        Details        = "No periods to verify"
        NextSteps      = @("Run Steps 4-5 first to discover periods and select scope")
        PeriodStatus   = $null
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 7] WhatIf: would run recon-troubleshoot across $($periodsToCheck.Count) PDF-backed periods" -Tags PRP
    return [PSCustomObject]@{
        StepNumber   = $stepNumber
        Passed       = $true
        Details      = "WhatIf: balance forward check skipped"
        PeriodStatus = $null
    }
}

$tasData = @()
if ($TasWorkingPath -and (Test-Path -LiteralPath $TasWorkingPath)) {
    try {
        $tasData = Import-Csv -LiteralPath $TasWorkingPath
        Write-Information "[PRP STEP 7] Loaded $($tasData.Count) rows from working TAS" -Tags PRP
    } catch {
        Write-Warning "[PRP STEP 7] Could not load working TAS from $TasWorkingPath — falling back to ZohoAll"
    }
}

if ($tasData.Count -eq 0 -and $ZohoAll) {
    $tasData = $ZohoAll
    Write-Information "[PRP STEP 7] Using ZohoAll directly ($($tasData.Count) records)" -Tags PRP
}

$periodResults = @{}
$allPassed = $true
$troubleshootLines = @("# Recon-Troubleshoot Report: $AccountName", "**Run**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "")

$parsed = $periodsToCheck | ForEach-Object {
    $end = if ($_.period_end -is [datetime]) { $_.period_end } elseif ($_.end -is [datetime]) { $_.end } else {
        $parsed = $null; [datetime]::TryParse($_.period_end -or $_.end, [ref]$parsed) | Out-Null; $parsed
    }
    $close = if ($_.closing_balance) { [decimal]$_.closing_balance } else { 0 }
    $openVal = if ($_.opening_balance) { [decimal]$_.opening_balance } else { $null }
    [PSCustomObject]@{
        period_end      = $end
        closing_balance = $close
        opening_balance = $openVal
    }
} | Where-Object { $_.period_end } | Sort-Object period_end

# Compute opening balance from prior period closing if not provided
for ($i = 0; $i -lt $parsed.Count; $i++) {
    if ($null -eq $parsed[$i].opening_balance -and $i -gt 0) {
        $parsed[$i].opening_balance = $parsed[$i - 1].closing_balance
    } elseif ($null -eq $parsed[$i].opening_balance) {
        $parsed[$i].opening_balance = 0
    }
}

foreach ($period in $parsed) {
    $endDate = $period.period_end
    $label = $endDate.ToString('yyyy-MM-dd')

    # Filter TAS/Zoho to transactions on or before this period end
    $periodTxns = $tasData | Where-Object {
        $d = if ($_.date -is [datetime]) { $_.date } else { $null; [datetime]::TryParse("$($_.date)", [ref]$null) | Out-Null; $null }
        if (-not $d) { return $false }
        $d -le $endDate
    }

    # Exclude transactions already counted in prior periods
    # (period filter ensures windows don't overlap — each period end is unique)
    if ($lastEndDate) {
        $periodTxns = $periodTxns | Where-Object {
            $d = if ($_.date -is [datetime]) { $_.date } else { [datetime]::Parse("$($_.date)") }
            $d -gt $lastEndDate
        }
    }

    # Compute net flow: debits - credits (amounts may be positive for debits, negative for credits)
    $debits = 0; $credits = 0
    foreach ($txn in $periodTxns) {
        $amt = [decimal]($txn.amount -or 0)
        $type = $txn.transaction_type -or $txn.debit_or_credit -or ""
        if ($type -eq "credit" -or $amt -lt 0) { $credits += [math]::Abs($amt) }
        else { $debits += $amt }
    }
    $netFlow = [math]::Round($debits - $credits, 2)

    $priorClose = if ($lastEndDate) { $lastClose } else { 0 }
    $expectedClosing = [math]::Round($priorClose + $netFlow, 2)
    $actualClosing = [math]::Round($period.closing_balance, 2)
    $diff = [math]::Round($expectedClosing - $actualClosing, 2)
    $passed = [math]::Abs($diff) -le $AmountTolerance

    if (-not $passed) { $allPassed = $false }

    # Find likely culprits (largest individual transactions in this period)
    $sortedTxns = $periodTxns | Sort-Object { [math]::Abs([decimal]($_.amount -or 0)) } -Descending | Select-Object -First 5

    $periodResults[$label] = @{
        OpeningBalance  = $priorClose
        NetFlow         = $netFlow
        Debits          = $debits
        Credits         = $credits
        ExpectedClose   = $expectedClosing
        ActualClose     = $actualClosing
        Diff            = $diff
        Passed          = $passed
        TopTxns         = @($sortedTxns | ForEach-Object { "$($_.date) | $($_.description -or '') | $($_.amount)" })
    }

    $status = if ($passed) { "PASS" } else { "FAIL" }
    Write-Information "[PRP STEP 7] Period $label`: Open=$priorClose + Flow=$netFlow = Expected=$expectedClosing vs Actual=$actualClosing (diff=$diff) [$status]" -Tags PRP

    $troubleshootLines += "Period: $label"
    $troubleshootLines += "  Statement Closing: $($actualClosing.ToString('C'))"
    $troubleshootLines += "  Computed Closing:  $($expectedClosing.ToString('C'))  $(if ($passed) { '✓' } else { '✗ ($diff)' })"
    if (-not $passed -and $sortedTxns.Count -gt 0) {
        $troubleshootLines += "  Likely items:"
        foreach ($t in $sortedTxns) {
            $tDate = if ($t.date -is [datetime]) { $t.date.ToString('yyyy-MM-dd') } else { "$($t.date)" }
            $tDesc = "$($t.description -or '')".Substring(0, [math]::Min(40, "$($t.description -or '')".Length))
            $tAmt = [math]::Round([decimal]($t.amount -or 0), 2)
            $troubleshootLines += "    $tDate | $tDesc | $tAmt"
        }
    }
    $troubleshootLines += ""

    $lastEndDate = $endDate
    $lastClose = $actualClosing
}

$detail = "$($parsed.Count) period(s) checked: $(if ($allPassed) { 'all balance forward verified' } else { 'some periods have discrepancies' })"

# Save recon-troubleshoot report
$null = New-Item -ItemType Directory -Path $troubleshootLogDir -Force
$reportPath = Join-Path $troubleshootLogDir "recon-troubleshoot-$AccountName-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
$troubleshootLines -join "`n" | Out-String | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Information "[PRP STEP 7] recon-troubleshoot report saved to $reportPath" -Tags PRP

if ($allPassed) {
    Write-Information "[PRP STEP 7] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 7] FAILED — $detail"
    foreach ($entry in $periodResults.GetEnumerator()) {
        if (-not $entry.Value.Passed) {
            Write-Warning "  Period $($entry.Key): diff=$($entry.Value.Diff)"
        }
    }
}

Write-Progress -Activity "[PRP Step 7]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber    = $stepNumber
    Passed        = $allPassed
    Details       = $detail
    PeriodStatus  = $periodResults
    ReportPath    = $reportPath
    NextSteps     = @(
        $(if ($allPassed) { "Proceed to Step 8: Hybrid Reconciliation" }
          else { "Identify gap period and transaction, fix via API, re-fetch, re-run Step 7. See recon-troubleshoot report for details." })
    )
}
