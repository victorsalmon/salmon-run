<#
.DEPRECATED
    Renamed to Invoke-PrpStep7-BalanceForward.ps1 (PRP reorder, now uses
    recon-troubleshoot). This file kept for backward compatibility.
.SYNOPSIS
    DEPRECATED — PRP Step 5: Three-way balance forward verification.
.DESCRIPTION
    Runs three-way net flow comparison (Sidecar vs TAS vs Zoho) and balance
    forward check for each period. Returns per-period pass/fail status.
.PARAMETER SidecarData
    Array of sidecar transaction objects with date, amount, credit/debit.
.PARAMETER TasData
    Array of TAS transaction objects with date, amount, account fields.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions array.
.PARAMETER SidecarPeriods
    Array of period objects with start, end, opening_balance, closing_balance.
.PARAMETER AmountTolerance
    Dollar tolerance for amount comparison (default: 0.50).
.PARAMETER BalanceTolerance
    Dollar tolerance for balance forward check (default: 0.01).
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
    Invoke-PrpStep5-BalanceForward.ps1 -SidecarData $sidecars -ZohoAll $zohoAll -SidecarPeriods $periods
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$SidecarData,

    [Parameter()]
    [array]$TasData,

    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [array]$SidecarPeriods,

    [decimal]$AmountTolerance = 0.50,

    [decimal]$BalanceTolerance = 0.01,

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
$stepNumber = 5
$stepName = "Balance Forward Verification"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if (-not $SidecarPeriods -or $SidecarPeriods.Count -eq 0) {
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $false
        Details       = "No sidecar periods provided"
        NextSteps     = @("Run Step 1 (Sidecar Verify) first")
        PeriodStatus  = $null
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 5] WhatIf: would run three-way net flow comparison across $($SidecarPeriods.Count) periods" -Tags PRP
    return [PSCustomObject]@{
        StepNumber   = $stepNumber
        Passed       = $true
        Details      = "WhatIf: balance forward check skipped"
        NextSteps    = @("Run without -WhatIf to execute verification")
        PeriodStatus = $null
    }
}

$periodStatus = @{}
$allPassed = $true

foreach ($period in $SidecarPeriods) {
    $startDate = if ($period.start -is [datetime]) { $period.start } else {
        $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($period.start.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse start date '$($period.start)'" }
    }
    $endDate = if ($period.end -is [datetime]) { $period.end } else {
        $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($period.end.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse end date '$($period.end)'" }
    }
    $periodLabel = "$($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"

    # Step 5a: Three-way net flow comparison
    # Sidecar net flow
    $periodSidecar = if ($SidecarData) {
        $SidecarData | Where-Object {
            $txnDate = if ($_.date -is [datetime]) { $_.date } else {
                $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($_.date.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse date '$($_.date)'" }
            }
            $txnDate -ge $startDate -and $txnDate -le $endDate
        }
    } else { @() }

    $scCredits = ($periodSidecar | Where-Object { $_.type -eq "credit" -or $_.direction -eq "credit" } | Measure-Object amount -Sum).Sum
    $scDebits = ($periodSidecar | Where-Object { $_.type -eq "debit" -or $_.direction -eq "debit" } | Measure-Object amount -Sum).Sum
    $sidecarNet = [math]::Round(($scCredits - $scDebits), 2)

    # TAS net flow
    $periodTas = if ($TasData) {
        $TasData | Where-Object {
            $txnDate = if ($_.date -is [datetime]) { $_.date } else {
                $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($_.date.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse date '$($_.date)'" }
            }
            $txnDate -ge $startDate -and $txnDate -le $endDate
        }
    } else { @() }
    $tasNet = [math]::Round(($periodTas | Measure-Object amount -Sum).Sum, 2)

    # Zoho net flow
    $periodZoho = if ($ZohoAll) {
        $ZohoAll | Where-Object {
            $txnDate = if ($_.date -is [datetime]) { $_.date } else {
                $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($_.date.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse date '$($_.date)'" }
            }
            $txnDate -ge $startDate.AddDays(-2) -and $txnDate -le $endDate.AddDays(2)
        }
    } else { @() }
    $zohoAmounts = $periodZoho | Where-Object { $_.amount -ne $null }
    $zohoNet = [math]::Round(($zohoAmounts | Measure-Object amount -Sum).Sum, 2)

    # Compare flows
    $scVsTas = [math]::Abs($sidecarNet - $tasNet)
    $scVsZoho = [math]::Abs($sidecarNet - $zohoNet)
    $tasVsZoho = [math]::Abs($tasNet - $zohoNet)

    $flowPassed = ($scVsTas -le $AmountTolerance) -and ($scVsZoho -le $AmountTolerance) -and ($tasVsZoho -le $AmountTolerance)

    # Step 5b: Balance forward check
    $balancePassed = $true
    $balanceDiff = $null
    if ($period.opening_balance -and $period.closing_balance) {
        $expectedClosing = [math]::Round(($period.opening_balance + $sidecarNet), 2)
        $balanceDiff = [math]::Round(($period.closing_balance - $expectedClosing), 2)
        $balancePassed = [math]::Abs($balanceDiff) -le $BalanceTolerance
    }

    $periodOk = $flowPassed -and $balancePassed
    if (-not $periodOk) { $allPassed = $false }

    $periodStatus[$periodLabel] = @{
        SidecarNet     = $sidecarNet
        TasNet         = $tasNet
        ZohoNet        = $zohoNet
        ScVsTasDiff    = $scVsTas
        ScVsZohoDiff   = $scVsZoho
        FlowPassed     = $flowPassed
        OpeningBalance = $period.opening_balance
        SidecarFlow    = $sidecarNet
        ExpectedClose  = if ($period.opening_balance) { [math]::Round($period.opening_balance + $sidecarNet, 2) } else { $null }
        ActualClose    = $period.closing_balance
        BalanceDiff    = $balanceDiff
        BalancePassed  = $balancePassed
        Passed         = $periodOk
    }

    $flowStatus = if ($flowPassed) { "PASS" } else { "FAIL" }
    $balStatus = if ($balancePassed) { "PASS" } else { "FAIL" }
    Write-Information "[PRP STEP 5] Period $periodLabel`: NetFlow=$sidecarNet (SC) vs $tasNet (TAS) vs $zohoNet (Zoho) [$flowStatus]" -Tags PRP
    if ($balanceDiff -ne $null) {
        Write-Information "[PRP STEP 5] Balance: Open=$($period.opening_balance) + Flow=$sidecarNet = Expected=$([math]::Round($period.opening_balance + $sidecarNet, 2)) vs Actual=$($period.closing_balance) (diff=$balanceDiff) [$balStatus]" -Tags PRP
    }
}

$detail = "$($SidecarPeriods.Count) periods checked: $(if ($allPassed) { 'all balance forward verified' } else { 'some periods have discrepancies' })"

if ($allPassed) {
    Write-Information "[PRP STEP 5] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 5] FAILED — $detail"
    foreach ($entry in $periodStatus.GetEnumerator()) {
        if (-not $entry.Value.Passed) {
            Write-Warning "  Period $($entry.Key): Flow=$($entry.Value.FlowPassed), Balance=$($entry.Value.BalancePassed)"
        }
    }
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber   = $stepNumber
    Passed       = $allPassed
    Details      = $detail
    PeriodStatus = $periodStatus
    NextSteps    = @(
        $(if ($allPassed) { "Proceed to Step 6: Hybrid Reconciliation" }
          else { "Identify gap period and transaction, fix via API, re-fetch, re-run Step 5" })
    )
}
