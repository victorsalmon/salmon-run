<#
.SYNOPSIS
    PRP Step 5.5 — Drift Correction (Posting-Date Alignment)
.DESCRIPTION
    Identifies posting-date drift pairs from Balance Forward results and
    attempts automated correction via DELETE + POST /expenses + receipt re-upload.
    Delegates to recon-drift-transaction-move.md for the detailed order of operations.
.PARAMETER BalanceForwardResults
    Results from Step 5 BalanceForward containing per-period pass/fail and diff amounts.
.PARAMETER SidecarPeriods
    Sidecar period definitions from Step 1.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transaction data.
.PARAMETER TasData
    TAS transaction data.
.PARAMETER IsPlaidImmutable
    Whether this account has Plaid-immutable transactions.
.PARAMETER Token
    Zoho OAuth token.
.PARAMETER Headers
    Zoho API headers.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$BalanceForwardResults,
    [Parameter()]
    [array]$SidecarPeriods,
    [Parameter()]
    [array]$ZohoAll,
    [Parameter()]
    [array]$TasData,
    [bool]$IsPlaidImmutable = $false,
    [string]$Token,
    [hashtable]$Headers,
    [string]$OrgId,
    [string]$AccountId,

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = "5.5"
$stepName = "Drift Correction"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

function Invoke-ZohoApiWithRetry {
    param([scriptblock]$ScriptBlock, [int]$MaxRetries = 3, [int]$BaseDelayMs = 1000)
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try { return & $ScriptBlock }
        catch {
            $lastError = $_
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { 0 }
            if ($attempt -lt $MaxRetries -and ($statusCode -in @(401, 429, 500, 502, 503, 504) -or $statusCode -eq 0)) {
                $delay = $BaseDelayMs * [math]::Pow(2, $attempt - 1)
                Start-Sleep -Milliseconds $delay
            } else { throw $lastError }
        }
    }
    throw $lastError
}

function Invoke-DriftDelete {
    param([string]$TransactionId, [string]$ZohoOrgId)
    $uri = "https://www.zohoapis.com/books/v3/banktransactions/$TransactionId?organization_id=$ZohoOrgId"
    Invoke-ZohoApiWithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method Delete } | Out-Null
    Write-Information "[DRIFT DELETE] Deleted banktransaction $TransactionId" -Tags PRP
}

function Invoke-DriftExpenseCreate {
    param([string]$Date, [string]$AccountId, [double]$Amount, [string]$Description, [string]$ZohoOrgId)
    $body = @{ date = $Date; account_id = $AccountId; amount = $Amount; description = $Description; reference_number = "" } | ConvertTo-Json
    $uri = "https://www.zohoapis.com/books/v3/expenses?organization_id=$ZohoOrgId"
    $response = Invoke-ZohoApiWithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $Headers -Method Post -Body $body -ContentType "application/json" }
    $expenseId = $response.expense.expense_id
    Write-Information "[DRIFT EXPENSE] Created expense $expenseId for $Description on $Date ($Amount)" -Tags PRP
    return $expenseId
}

function Invoke-DriftReceiptDownload {
    param([string]$ExpenseId, [string]$ZohoOrgId)
    try {
        $uri = "https://www.zohoapis.com/books/v3/expenses/$ExpenseId/receipt?organization_id=$ZohoOrgId"
        $tempPath = Join-Path $env:TEMP "prp-drift-receipt-$ExpenseId.pdf"
        Invoke-WebRequest -Uri $uri -Headers $Headers -OutFile $tempPath
        Write-Information "[DRIFT RECEIPT] Downloaded receipt for expense $ExpenseId to $tempPath" -Tags PRP
        return $tempPath
    } catch {
        Write-Warning "[DRIFT RECEIPT] Could not download receipt for expense $($ExpenseId): $_"
        return $null
    }
}

function Invoke-DriftReceiptUpload {
    param([string]$ExpenseId, [string]$ReceiptPath, [string]$ZohoOrgId)
    if (-not (Test-Path $ReceiptPath)) { Write-Warning "[DRIFT RECEIPT] Receipt file not found: $ReceiptPath"; return }
    try {
        $uri = "https://www.zohoapis.com/books/v3/expenses/$ExpenseId/receipt?organization_id=$ZohoOrgId"
        $boundary = [Guid]::NewGuid().ToString("N")
        $fileBytes = [System.IO.File]::ReadAllBytes($ReceiptPath)
        $fileContent = [System.Text.Encoding]::GetEncoding("iso-8859-1").GetString($fileBytes)
        $body = "--$boundary`r`nContent-Disposition: form-data; name=`"receipt`"; filename=`"$(Split-Path -Leaf $ReceiptPath)`"`r`nContent-Type: application/pdf`r`n`r`n$fileContent`r`n--$boundary--`r`n"
        $headersWithBoundary = $Headers.Clone()
        $headersWithBoundary["Content-Type"] = "multipart/form-data; boundary=$boundary"
        Invoke-ZohoApiWithRetry -ScriptBlock { Invoke-RestMethod -Uri $uri -Headers $headersWithBoundary -Method Post -Body $body } | Out-Null
        Write-Information "[DRIFT RECEIPT] Uploaded receipt to expense $ExpenseId" -Tags PRP
        Remove-Item -LiteralPath $ReceiptPath -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "[DRIFT RECEIPT] Could not upload receipt for expense $($ExpenseId): $_"
    }
}

function Find-FloatingTransactions {
    param([array]$PeriodATransactions, [array]$PeriodBTransactions)
    $intersection = @()
    foreach ($txnA in $PeriodATransactions) {
        $match = $PeriodBTransactions | Where-Object {
            [math]::Abs($_.amount) -eq [math]::Abs($txnA.amount) -and
            $_.desc -eq $txnA.desc
        } | Select-Object -First 1
        if ($match) { $intersection += $txnA }
    }
    return $intersection
}

# If Plaid-immutable, drift correction is not possible — report and exit
if ($IsPlaidImmutable) {
    return [PSCustomObject]@{
        Passed       = $true
        StepNumber   = $stepNumber
        Details      = "Plaid-immutable account — drift correction skipped. User must accept differences in Zoho reconciliation UI."
        NextSteps    = @("Proceed to Step 6 with drift periods flagged as non-correctable")
        DriftFixed   = @()
        DriftSkipped = @($BalanceForwardResults | Where-Object { -not $_.Passed } | ForEach-Object { $_.PeriodLabel })
    }
}

$driftPairs = @()
$allPeriods = $BalanceForwardResults
$corrected = @()
$skipped = @()

# Step 1: Identify drift pairs (adjacent periods with equal-and-opposite diffs)
for ($i = 0; $i -lt $allPeriods.Count - 1; $i++) {
    $current = $allPeriods[$i]
    $next = $allPeriods[$i + 1]
    if (-not $current.Passed -and -not $next.Passed) {
        $diffSum = [math]::Round([double]$current.Diff + [double]$next.Diff, 2)
        $absCurrent = [math]::Abs([double]$current.Diff)
        if (($diffSum -eq 0 -and $absCurrent -gt 0.50) -or ([math]::Abs($diffSum) -lt 1.00 -and $absCurrent -gt 0.50)) {
            $driftPairs += @{
                PeriodA = $current.PeriodLabel
                PeriodB = $next.PeriodLabel
                DriftAmount = [math]::Abs([double]$current.Diff)
            }
        }
    }
}

# Pass 2: For remaining failing periods, find floating transactions
if ($allPeriods.Count -ge 2) {
    for ($i = 0; $i -lt $allPeriods.Count - 1; $i++) {
        $current = $allPeriods[$i]
        $next = $allPeriods[$i + 1]
        if (-not $current.Passed -and -not $next.Passed) {
            $alreadyPaired = $driftPairs | Where-Object { $_.PeriodA -eq $current.PeriodLabel -and $_.PeriodB -eq $next.PeriodLabel }
            if (-not $alreadyPaired) {
                $floating = Find-FloatingTransactions -PeriodATransactions $current.UnmatchedTasOnly -PeriodBTransactions $next.UnmatchedStmtOnly
                if ($floating.Count -gt 0) {
                    $totalFloat = ($floating | Measure-Object -Property amount -Sum).Sum
                    $driftPairs += @{
                        PeriodA = $current.PeriodLabel
                        PeriodB = $next.PeriodLabel
                        DriftAmount = [math]::Abs($totalFloat)
                        FloatingTxns = $floating
                    }
                }
            }
        }
    }
}

# Step 2: For each drift pair, identify individual transactions and attempt correction
foreach ($pair in $driftPairs) {
    Write-Information "[DRIFT CORRECTION] Processing drift pair: $($pair.PeriodA) ↔ $($pair.PeriodB) — $($pair.DriftAmount)" -Tags PRP

    $periodAEnd = ($pair.PeriodA -split ' to ')[1]
    $periodBStart = ($pair.PeriodB -split ' to ')[0]

    $boundaryStart = (Get-Date $periodBStart).AddDays(-14)
    $boundaryEnd = (Get-Date $periodBStart)

    $candidates = if ($pair.FloatingTxns) {
        $pair.FloatingTxns
    } else {
        $TasData | Where-Object {
            $_.date -ge $boundaryStart.ToString('yyyy-MM-dd') -and
            $_.date -le $boundaryEnd.ToString('yyyy-MM-dd') -and
            [math]::Abs($_.amount) -le $pair.DriftAmount * 2
        }
    }

    $pairCorrected = 0
    $pairSkipped = 0

    foreach ($txn in $candidates) {
        $targetDate = (Get-Date $txn.date).AddDays(1).ToString('yyyy-MM-dd')

        # Find the Zoho transaction by matching (date, Abs(amount), description)
        $zohoTxn = $ZohoAll | Where-Object {
            $_.date -eq $txn.date -and
            [math]::Abs([double]$_.amount) -eq [math]::Abs([double]$txn.amount) -and
            $_.description -like "*$($txn.desc)*"
        } | Select-Object -First 1

        if (-not $zohoTxn) {
            Write-Warning "[DRIFT CORRECTION]   Could not find Zoho transaction matching $($txn.date) $($txn.desc) — skipping"
            $pairSkipped++
            continue
        }

        $zohoTransactionId = $zohoTxn.transaction_id
        if (-not $zohoTransactionId) {
            Write-Warning "[DRIFT CORRECTION]   Zoho transaction has no transaction_id — skipping"
            $pairSkipped++
            continue
        }

        Write-Information "[DRIFT CORRECTION]   Processing $($txn.date) $($txn.desc) ($($txn.amount)) — Zoho ID: $zohoTransactionId" -Tags PRP

        # 1. Check receipt and download
        $receiptPath = $null
        if ($zohoTxn.has_attachment -or $zohoTxn.zoho_has_receipt) {
            $receiptPath = Invoke-DriftReceiptDownload -ExpenseId $zohoTransactionId -ZohoOrgId $OrgId
        }

        # 2. DELETE the drifting banktransaction
        try {
            Invoke-DriftDelete -TransactionId $zohoTransactionId -ZohoOrgId $OrgId
        } catch {
            Write-Warning "[DRIFT CORRECTION]   DELETE failed for $($zohoTransactionId): $_ — skipping"
            $pairSkipped++
            continue
        }

        # 3. POST new expense with corrected date and same category
        $categoryAccountId = if ($zohoTxn.account_id) { $zohoTxn.account_id } else { $AccountId }
        try {
            $newExpenseId = Invoke-DriftExpenseCreate -Date $targetDate -AccountId $categoryAccountId -Amount $txn.amount -Description $txn.desc -ZohoOrgId $OrgId
        } catch {
            Write-Warning "[DRIFT CORRECTION]   Expense create failed: $_ — skipping"
            $pairSkipped++
            continue
        }

        # 4. If receipt was downloaded, upload to new expense
        if ($receiptPath) {
            Invoke-DriftReceiptUpload -ExpenseId $newExpenseId -ReceiptPath $receiptPath -ZohoOrgId $OrgId
        }

        $pairCorrected++
        Write-Information "[DRIFT CORRECTION]   Corrected: $($txn.date) → $targetDate ($($txn.amount))" -Tags PRP
    }

    if ($pairCorrected -gt 0) {
        $corrected += @{ PeriodA = $pair.PeriodA; PeriodB = $pair.PeriodB; Corrected = $pairCorrected; Skipped = $pairSkipped }
    }
    if ($pairSkipped -gt 0) {
        $skipped += @{ PeriodA = $pair.PeriodA; PeriodB = $pair.PeriodB; Corrected = $pairCorrected; Skipped = $pairSkipped }
    }
}

# Return results
$allPassed = $driftPairs.Count -eq 0
$details = if ($allPassed) {
    "No drift pairs detected — all periods pass Balance Forward"
} elseif ($corrected.Count -eq $driftPairs.Count) {
    "$($corrected.Count) drift pairs corrected — re-run Balance Forward to verify"
} else {
    "$($corrected.Count)/$($driftPairs.Count) drift pairs corrected — $($skipped.Count) skipped"
}

return [PSCustomObject]@{
    Passed       = $true  # Drift correction step does not fail — it classifies and attempts
    StepNumber   = $stepNumber
    Details      = $details
    NextSteps    = @("Re-run Step 5 Balance Forward to verify corrections", "Proceed to Step 6 Reconciliation")
    DriftPairs   = $driftPairs
    DriftFixed   = $corrected
    DriftSkipped = $skipped
}
