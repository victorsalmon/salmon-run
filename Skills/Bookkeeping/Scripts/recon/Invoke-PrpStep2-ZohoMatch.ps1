<#
.SYNOPSIS
    PRP Step 2: Match Zoho transactions against sidecar data per period.
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

    [decimal]$AmountTolerance = 0.50,

    [bool]$HasPostSidecarData = $false,

    [Parameter()]
    [string]$Platform = 'Host'
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

# If post-sidecar Zoho data exists, exclude those transactions from period comparison
$filteredZoho = $ZohoAll
if ($HasPostSidecarData -and $SidecarPeriods.Count -gt 0 -and $ZohoAll -and $ZohoAll.Count -gt 0) {
    $periodEnds = $SidecarPeriods | ForEach-Object {
        if ($_.end -is [datetime]) { $_.end } else {
            try { [datetime]::ParseExact($_.end.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::MinValue }
        }
    }
    $maxEnd = ($periodEnds | Measure-Object -Maximum).Maximum
    $filteredZoho = $ZohoAll | Where-Object {
        $txnDate = if ($_.date -is [datetime]) { $_.date } else {
            try { [datetime]::ParseExact($_.date.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::MinValue }
        }
        $txnDate -le $maxEnd -or $txnDate -eq [datetime]::MinValue
    }
    Write-Information "[PRP STEP 2] Excluded $($ZohoAll.Count - $filteredZoho.Count) post-sidecar transaction(s) from period comparison" -Tags PRP
}

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

    $zohoCount = ($filteredZoho | Where-Object {
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

if ($HasPostSidecarData) {
    $detail += " | Post-sidecar Zoho data excluded from comparison"
}

if ($allPassed) {
    Write-Information "[PRP STEP 2] PASSED — $detail" -Tags PRP
    if ($HasPostSidecarData) {
        $postSidecarExcluded = $ZohoAll.Count - $filteredZoho.Count
        Write-Information "[STEP 2] Tip: Re-run monthly Zoho export (export-zoho-csv.mjs) to capture the $postSidecarExcluded post-sidecar transactions" -Tags PRP
    }
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

<#
.SYNOPSIS
    Find matching cross-account transfer pairs across two accounts.
.DESCRIPTION
    Looks for opposite-direction transactions (debit in account A, credit in
    account B) with matching amounts within tolerance and dates within proximity.
    This identifies inter-account transfers that cause false discrepancies when
    each account is reconciled independently.
.PARAMETER AccountATxns
    Zoho banktransactions array for account A.
.PARAMETER AccountBTxns
    Zoho banktransactions array for account B.
.PARAMETER AccountALabel
    Display label for account A (e.g. "RBC-INTERSITE").
.PARAMETER AccountBLabel
    Display label for account B (e.g. "MC-6258").
.PARAMETER AmountTolerance
    Maximum allowed amount difference (default: 0.50).
.PARAMETER DateToleranceDays
    Maximum allowed date gap in days (default: 3).
.EXAMPLE
    $matches = Find-CrossAccountTransfers -AccountATxns $txnsA -AccountBTxns $txnsB -AccountALabel "RBC-INTERSITE" -AccountBLabel "MC-6258"
#>
function Find-CrossAccountTransfers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$AccountATxns,

        [Parameter(Mandatory)]
        [array]$AccountBTxns,

        [Parameter(Mandatory)]
        [string]$AccountALabel,

        [Parameter(Mandatory)]
        [string]$AccountBLabel,

        [decimal]$AmountTolerance = 0.50,

        [int]$DateToleranceDays = 3
    )

    function Get-TxnAmount {
        param($txn)
        if ($txn.debit_amount) { return [decimal]$txn.debit_amount }
        if ($txn.credit_amount) { return [decimal]$txn.credit_amount }
        return [decimal]$txn.amount
    }

    function Get-TxnDate {
        param($txn)
        if ($txn.transaction_date -is [datetime]) { return $txn.transaction_date }
        if ($txn.date -is [datetime]) { return $txn.date }
        $dtStr = if ($txn.transaction_date) { $txn.transaction_date } else { $txn.date }
        $parsed = $null; $fmts = @("yyyy-MM-dd", "yyyy-MM-ddTHH:mm:ss", "MM/dd/yyyy", "M/d/yyyy")
        foreach ($_fmt in $fmts) { try { $parsed = [datetime]::ParseExact($dtStr.Trim(), $_fmt, [System.Globalization.CultureInfo]::InvariantCulture); break } catch {} }
        if (-not $parsed) { $parsed = [datetime]::MinValue }
        return $parsed
    }

    function Get-TxnDescription {
        param($txn)
        if ($txn.description) { return "$($txn.description)" }
        if ($txn.payee) { return "$($txn.payee)" }
        return ""
    }

    function Get-TxnDirection {
        param($txn)
        if ($txn.transaction_type -eq "credit" -or $txn.credit_amount -gt 0) { return "credit" }
        if ($txn.transaction_type -eq "debit" -or $txn.debit_amount -gt 0) { return "debit" }
        if ($txn.amount -gt 0) { return "credit" }
        return "debit"
    }

    function Test-TransferDescription {
        param([string]$DescA, [string]$DescB)
        if ([string]::IsNullOrWhiteSpace($DescA) -or [string]::IsNullOrWhiteSpace($DescB)) { return $false }
        $upperA = $DescA.ToUpperInvariant()
        $upperB = $DescB.ToUpperInvariant()
        $transferKeywords = @("ONLINE BANKING TRANSFER", "CREDIT CARD PAYMENT", "PAYMENT - THANK YOU", "BILL PAYMENT", "TRANSFER", "E-TRANSFER", "FUNDS TRANSFER")
        foreach ($kw in $transferKeywords) {
            if (($upperA.Contains($kw) -and $upperB.Contains($kw)) -or
                ($upperA.Contains($kw) -and $upperB.Contains("PAYMENT")) -or
                ($upperA.Contains("PAYMENT") -and $upperB.Contains($kw))) {
                return $true
            }
        }
        return $false
    }

    function Get-Confidence {
        param([decimal]$AmountDiff, [int]$DaysDiff, [bool]$DescMatch)
        if ($AmountDiff -eq 0 -and $DaysDiff -le 1 -and $DescMatch) { return "high" }
        if ($AmountDiff -le 0.50 -and $DaysDiff -le 3 -and $DescMatch) { return "high" }
        if ($AmountDiff -le 0.50 -and $DaysDiff -le 3) { return "medium" }
        if ($AmountDiff -le ($AmountTolerance * 2) -and $DaysDiff -le $DateToleranceDays) { return "low" }
        return "none"
    }

    Write-Information "[CROSS-ACCOUNT] Scanning $($AccountATxns.Count) txns in $AccountALabel vs $($AccountBTxns.Count) txns in $AccountBLabel" -Tags PRP

    # Classify transactions by direction
    $debitsA = $AccountATxns | Where-Object { (Get-TxnDirection $_) -eq "debit" }
    $creditsA = $AccountATxns | Where-Object { (Get-TxnDirection $_) -eq "credit" }
    $debitsB = $AccountBTxns | Where-Object { (Get-TxnDirection $_) -eq "debit" }
    $creditsB = $AccountBTxns | Where-Object { (Get-TxnDirection $_) -eq "credit" }

    $matches = @()
    $matchedIdsA = @{}; $matchedIdsB = @{}

    # Compare debits(A) against credits(B) — A sends money to B
    foreach ($debit in $debitsA) {
        $dAmt = Get-TxnAmount $debit
        $dDate = Get-TxnDate $debit
        $dDesc = Get-TxnDescription $debit
        $dId = if ($debit.transaction_id) { $debit.transaction_id } else { $debit.banktransaction_id }

        foreach ($credit in $creditsB) {
            $cId = if ($credit.transaction_id) { $credit.transaction_id } else { $credit.banktransaction_id }
            if ($matchedIdsB.ContainsKey($cId)) { continue }

            $cAmt = Get-TxnAmount $credit
            $cDate = Get-TxnDate $credit
            $cDesc = Get-TxnDescription $credit

            $amtDiff = [math]::Abs($dAmt - $cAmt)
            $daysDiff = [math]::Abs(($dDate - $cDate).TotalDays)

            if ($amtDiff -le $AmountTolerance -and $daysDiff -le $DateToleranceDays) {
                $descMatch = Test-TransferDescription -DescA $dDesc -DescB $cDesc
                $confidence = Get-Confidence -AmountDiff $amtDiff -DaysDiff $daysDiff -DescMatch $descMatch

                if ($confidence -ne "none") {
                    $dateRange = "$($dDate.ToString('yyyy-MM-dd')) to $($cDate.ToString('yyyy-MM-dd'))"
                    $displayDesc = if ($dDesc) { $dDesc.Substring(0, [math]::Min(80, $dDesc.Length)) } else { "—" }

                    Write-Information "[CROSS-ACCOUNT] Transfer: Debit `$$dAmt in $AccountALabel → Credit `$$cAmt in $AccountBLabel matched (confidence: $confidence)" -Tags PRP

                    $matches += [PSCustomObject]@{
                        DebitAccount  = $AccountALabel
                        CreditAccount = $AccountBLabel
                        DebitDate     = $dDate.ToString('yyyy-MM-dd')
                        CreditDate    = $cDate.ToString('yyyy-MM-dd')
                        Amount        = $dAmt
                        Description   = $displayDesc
                        DateRange     = $dateRange
                        Confidence    = $confidence
                        DebitTxnId    = $dId
                        CreditTxnId   = $cId
                    }

                    if ($dId) { $matchedIdsA[$dId] = $true }
                    if ($cId) { $matchedIdsB[$cId] = $true }
                    break
                }
            }
        }
    }

    # Compare credits(A) against debits(B) — B sends money to A
    foreach ($credit in $creditsA) {
        $cAmt = Get-TxnAmount $credit
        $cDate = Get-TxnDate $credit
        $cDesc = Get-TxnDescription $credit
        $cId = if ($credit.transaction_id) { $credit.transaction_id } else { $credit.banktransaction_id }
        if ($matchedIdsA.ContainsKey($cId)) { continue }

        foreach ($debit in $debitsB) {
            $dId = if ($debit.transaction_id) { $debit.transaction_id } else { $debit.banktransaction_id }
            if ($matchedIdsB.ContainsKey($dId)) { continue }

            $dAmt = Get-TxnAmount $debit
            $dDate = Get-TxnDate $debit
            $dDesc = Get-TxnDescription $debit

            $amtDiff = [math]::Abs($cAmt - $dAmt)
            $daysDiff = [math]::Abs(($cDate - $dDate).TotalDays)

            if ($amtDiff -le $AmountTolerance -and $daysDiff -le $DateToleranceDays) {
                $descMatch = Test-TransferDescription -DescA $dDesc -DescB $cDesc
                $confidence = Get-Confidence -AmountDiff $amtDiff -DaysDiff $daysDiff -DescMatch $descMatch

                if ($confidence -ne "none") {
                    $dateRange = "$($dDate.ToString('yyyy-MM-dd')) to $($cDate.ToString('yyyy-MM-dd'))"
                    $displayDesc = if ($cDesc) { $cDesc.Substring(0, [math]::Min(80, $cDesc.Length)) } else { "—" }

                    Write-Information "[CROSS-ACCOUNT] Transfer: Credit `$$cAmt in $AccountALabel → Debit `$$dAmt in $AccountBLabel matched (confidence: $confidence)" -Tags PRP

                    $matches += [PSCustomObject]@{
                        DebitAccount  = $AccountBLabel
                        CreditAccount = $AccountALabel
                        DebitDate     = $dDate.ToString('yyyy-MM-dd')
                        CreditDate    = $cDate.ToString('yyyy-MM-dd')
                        Amount        = $cAmt
                        Description   = $displayDesc
                        DateRange     = $dateRange
                        Confidence    = $confidence
                        DebitTxnId    = $dId
                        CreditTxnId   = $cId
                    }

                    if ($cId) { $matchedIdsA[$cId] = $true }
                    if ($dId) { $matchedIdsB[$dId] = $true }
                    break
                }
            }
        }
    }

    Write-Information "[CROSS-ACCOUNT] Found $($matches.Count) matching transfer pair(s) between $AccountALabel and $AccountBLabel" -Tags PRP
    return $matches
}
