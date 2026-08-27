<#
.DEPRECATED
    Renamed to Invoke-PrpStep3-ZohoMatch.ps1 (PRP reorder). This file kept for
    backward compatibility. All new calls should use the new name.
.SYNOPSIS
    DEPRECATED — PRP Step 2: Match Zoho transactions against sidecar data per period.
.DESCRIPTION
    Accepts bulk-fetched Zoho dataset and sidecar data, runs per-period
    count comparison with posting-date drift tolerance. Returns per-period
    results hashtable and overall pass/fail.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions and expenses array (post-CR+DR sweep).
.PARAMETER SidecarData
    Sidecar transaction data array with date, amount, period fields.
.PARAMETER SidecarPeriods
    Array of period objects with start, end, label fields.
.PARAMETER IsPlaidImmutable
    Whether the account is Plaid-immutable (affects remediation).
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER ToleranceDays
    Posting-date drift tolerance in days (default: 2).
.PARAMETER AmountTolerance
    Amount tolerance for matching (default: 0.50).
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep2-ZohoMatch.ps1 -ZohoAll $zohoAll -SidecarData $sidecars -SidecarPeriods $periods
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [array]$SidecarData,

    [Parameter()]
    [array]$SidecarPeriods,

    [Parameter()]
    [bool]$IsPlaidImmutable = $false,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$OrgName,

    [Parameter()]
    [string]$AccountId,

    [int]$ToleranceDays = 2,

    [decimal]$AmountTolerance = 0.50
)

$ErrorActionPreference = "Stop"
$stepNumber = 2
$stepName = "Zoho Transaction Match"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if (-not $ZohoAll -or $ZohoAll.Count -eq 0) {
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $false
        Details       = "No Zoho dataset provided"
        NextSteps     = @("Run Step 0 (Token Acquisition) first to fetch data")
        PeriodResults = $null
    }
}

if (-not $SidecarPeriods -or $SidecarPeriods.Count -eq 0) {
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $false
        Details       = "No sidecar periods provided"
        NextSteps     = @("Run Step 1 (Sidecar Verify) first to load sidecar data")
        PeriodResults = $null
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 2] WhatIf: would compare $($ZohoAll.Count) Zoho transactions across $($SidecarPeriods.Count) periods" -Tags PRP
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $true
        Details       = "WhatIf: Zoho match skipped"
        NextSteps     = @("Run without -WhatIf to execute matching")
        PeriodResults = $null
    }
}

$periodResults = @{}
$allPassed = $true
$totalDiff = 0

foreach ($period in $SidecarPeriods) {
    $startDate = if ($period.start -is [datetime]) { $period.start } else {
        $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($period.start.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse start date '$($period.start)'" }
    }
    $endDate = if ($period.end -is [datetime]) { $period.end } else {
        $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($period.end.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse end date '$($period.end)'" }
    }

    $sidecarCount = ($SidecarData | Where-Object {
        $txnDate = if ($_.date -is [datetime]) { $_.date } else {
            $parsed = $null; $fmts = @("yyyy-MM-dd","yyyy-MM-ddTHH:mm:ss","MM/dd/yyyy","M/d/yyyy"); foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($_.date.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }; if (-not $parsed) { throw "Cannot parse date '$($_.date)'" }
        }
        $txnDate -ge $startDate -and $txnDate -le $endDate
    }).Count

    $zohoCount = ($ZohoAll | Where-Object {
        try {
            $txnDate = if ($_.date -is [datetime]) { $_.date } else {
                [datetime]::ParseExact($_.date.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            $rangeStart = $startDate.AddDays(-$ToleranceDays)
            $rangeEnd = $endDate.AddDays($ToleranceDays)
            $txnDate -ge $rangeStart -and $txnDate -le $rangeEnd
        } catch {
            Write-Warning "[PRP STEP 2 DEBUG] Filter failed: $($_.Exception.Message)"
            $false
        }
    }).Count

    $diff = $sidecarCount - $zohoCount
    $periodPassed = $diff -eq 0
    if (-not $periodPassed) { $allPassed = $false }
    $totalDiff += $diff

    $periodLabel = "$($period.start.ToString('yyyy-MM-dd')) to $($period.end.ToString('yyyy-MM-dd'))"
    $periodResults[$periodLabel] = @{
        SidecarCount = $sidecarCount
        ZohoCount    = $zohoCount
        Diff         = $diff
        Passed       = $periodPassed
    }

    $status = if ($periodPassed) { "PASS" } else { "FAIL" }
    Write-Information "[PRP STEP 2] Period $periodLabel`: $sidecarCount sidecar, $zohoCount Zoho, diff=$diff [$status]" -Tags PRP
}

$detail = "$($SidecarPeriods.Count) periods checked: $(if ($allPassed) { 'all matched' } else { "$totalDiff total discrepancy" })"

if ($allPassed) {
    Write-Information "[PRP STEP 2] PASSED — $detail" -Tags PRP
} else {
    Write-Warning "[PRP STEP 2] FAILED — $detail"
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber    = $stepNumber
    Passed        = $allPassed
    Details       = $detail
    PeriodResults = $periodResults
    TotalDiff     = $totalDiff
    IsPlaidImmutable = $IsPlaidImmutable
    NextSteps     = @(
        $(if ($allPassed) { "Proceed to Step 3: Categorization Audit" }
          elseif ($IsPlaidImmutable) { "Record discrepancies in remediation report — Plaid-immutable, process in Zoho UI" }
          else { "Fix discrepancies via API (DELETE extras / POST missing), then re-run Step 2" })
    )
}
