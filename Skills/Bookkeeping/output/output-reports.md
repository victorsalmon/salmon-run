# Zoho Books — Reconciled Output

## Overview

This skill defines the **final output** of the bookkeeping pipeline: the artifacts produced after reconciliation completes. Two deliverables are produced:

1. **Deliverable A: Receiptless Transactions** — a list of reconciled transactions that have no receipt image attached, organized by account
2. **Deliverable B: Balance Checkpoints** — bank balance snapshots at gap points in the transaction history, used as a triple-check that Zoho's ending balance matches reality

## Deliverable A: Receiptless Transactions Report

After reconciliation, some transactions will be matched and marked as reconciled in Zoho but may **lack an attached receipt image**. These fall into categories:

| Category | Example | Action |
|----------|---------|--------|
| Recurring fees with no receipt | Bank charges, monthly account fees | Acceptable — no receipt exists |
| Internal transfers | E-TRANSFER between accounts | Acceptable — excluded from review |
| Income/Deposits | Rent payments received | Acceptable — not expenses |
| Missing receipt | Purchase with no uploaded image | Flag — receipt may need upload |
| Old transactions | Pre-2023 with no digital receipt | Acceptable — paper-only |

### Script: Generate Receiptless Report

```powershell
function Get-ReceiptlessTransactions {
    param(
        [string]$OrgId,
        [string]$AccessToken,
        [string]$AccountId,
        [string]$StartDate,
        [string]$EndDate,
        [string]$OutputPath = "receiptless-transactions.csv"
    )
    $headers = @{ Authorization = "Zoho-oauthtoken $AccessToken" }

    # Fetch reconciled bank transactions
    $reconciled = @()
    $page = 1
    do {
        $uri = "https://www.zohoapis.com/books/v3/banktransactions?organization_id=$OrgId&status=reconciled&account_id=$AccountId&page=$page&per_page=200"
        if ($StartDate) { $uri += "&date_start=$StartDate" }
        if ($EndDate) { $uri += "&date_end=$EndDate" }
        $result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $reconciled += $result.banktransactions
        $page++
    } while ($result.page_context.has_more_page)

    # Fetch all expenses with their receipt status
    $expenses = @()
    $page = 1
    do {
        $uri = "https://www.zohoapis.com/books/v3/expenses?organization_id=$OrgId&page=$page&per_page=200"
        if ($StartDate) { $uri += "&date_start=$StartDate" }
        if ($EndDate) { $uri += "&date_end=$EndDate" }
        $result = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers
        $expenses += $result.expenses
        $page++
    } while ($result.page_context.has_more_page)

    # Build expense lookup by matched transaction ID
    $expenseLookup = @{}
    foreach ($exp in $expenses) {
        foreach ($imported in $exp.imported_transactions) {
            $expenseLookup[$imported.transaction_id] = @{
                expense_id = $exp.expense_id
                has_receipt = $exp.has_receipt -or $exp.expense_receipt_name
                vendor = $exp.vendor_name
                amount = $exp.amount
            }
        }
    }

    # Find reconciled transactions without receipt
    $receiptless = [System.Collections.Generic.List[object]]::new()
    foreach ($txn in $reconciled) {
        $match = $expenseLookup[$txn.transaction_id]
        if (-not $match -or -not $match.has_receipt) {
            $receiptless.Add([pscustomobject]@{
                transaction_id = $txn.transaction_id
                date           = $txn.date
                amount         = $txn.amount
                payee          = $txn.payee
                account_id     = $txn.account_id
                account_name   = $txn.account_name
                has_expense    = $match ? $true : $false
                expense_id     = $match ? $match.expense_id : ""
                has_receipt    = $match ? $match.has_receipt : $false
                reason         = $match ? "Expense exists but no receipt image" : "No matching expense"
            })
        }
    }

    # Export
    $receiptless | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Receiptless transactions: $($receiptless.Count) written to $OutputPath" -ForegroundColor Yellow

    # Summary by category
    $noExpense = $receiptless | Where-Object { -not $_.has_expense }
    $noReceipt = $receiptless | Where-Object { $_.has_expense -and -not $_.has_receipt }
    Write-Host "  Without any expense record: $($noExpense.Count)" -ForegroundColor Red
    Write-Host "  Expense exists but no receipt: $($noReceipt.Count)" -ForegroundColor Yellow

    return $receiptless
}
```

### Output Format

```csv
transaction_id,date,amount,payee,account_id,account_name,has_expense,expense_id,has_receipt,reason
151803000000147033,2026-04-30,2.00,CHQ RETURN FEE,151803000000101006,TD ABBOTSFORD,FALSE,,FALSE,No matching expense
```

## Deliverable B: Balance Checkpoints

### Purpose

Bank balances in Zoho Books may drift from actual bank balances due to:
- **Posting date lag** (1-5 days between purchase and bank clearing)
- **Missing transactions** (not yet imported from a PDF statement)
- **Duplicate transactions** (imported twice from different sources)

Balance checkpoints provide a **triple-check**: take snapshots of the actual bank balance at dates where **no transactions occurred**, so there is no ambiguity about which transactions should have posted. Any discrepancy at a quiet point means something is wrong.

### Selection Logic

1. Sort all bank transactions by date
2. Find gaps of ≥1 day between consecutive transaction dates
3. For each gap, select the **last day before the next transaction** as the checkpoint date
4. Report the bank balance that *should* appear in Zoho at that date

### Script: Generate Balance Checkpoints

```powershell
function Get-BalanceCheckpoints {
    param(
        [string]$CsvPath,                # Original bank CSV as source of truth
        [string]$AccountName,
        [int]$CsvDateCol = 0,
        [int]$CsvDescCol = 1,
        [int]$CsvDebitCol = 2,           # Debit column (negative/outgoing)
        [int]$CsvCreditCol = 3,          # Credit column (positive/incoming)
        [int]$CsvBalanceCol = 4,         # Running balance column (if available)
        [string]$OutputPath = "balance-checkpoints.csv"
    )
    $lines = Get-Content $CsvPath
    $txns = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        if ($line -match '^Account|^Date|^"date|^Transaction') { continue }
        $parts = $line -split ','
        if ($parts.Count -le [math]::Max($CsvDateCol, $CsvBalanceCol)) { continue }

        $d = Get-Date $parts[$CsvDateCol].Trim() -ErrorAction SilentlyContinue
        if (-not $d) { continue }

        $balance = [double]::TryParse(($parts[$CsvBalanceCol] -replace '[^0-9.-]', ''), [ref]$null) ? [double]($parts[$CsvBalanceCol] -replace '[^0-9.-]', '') : $null

        $txns.Add([pscustomobject]@{
            Date = $d
            DateStr = $d.ToString('yyyy-MM-dd')
            Description = $parts[$CsvDescCol].Trim()
            Balance = $balance
        })
    }

    if ($txns.Count -lt 2) {
        Write-Warning "Not enough transactions to compute checkpoints"
        return
    }

    # Sort by date
    $sorted = $txns | Sort-Object Date

    # Find gaps
    $checkpoints = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $prev = $sorted[$i - 1]
        $curr = $sorted[$i]
        $gapDays = ($curr.Date - $prev.Date).Days

        if ($gapDays -gt 1) {
            # Gap found: checkpoint is the day before the next transaction
            $checkpointDate = $curr.Date.AddDays(-1)
            # Use previous transaction's balance as the expected checkpoint value
            $expectedBalance = $prev.Balance

            $checkpoints.Add([pscustomobject]@{
                checkpoint_date      = $checkpointDate.ToString('yyyy-MM-dd')
                days_since_last_txn  = $gapDays
                last_txn_date        = $prev.DateStr
                last_txn_desc        = $prev.Description
                next_txn_date        = $curr.DateStr
                next_txn_desc        = $curr.Description
                expected_balance     = $expectedBalance
            })
        }
    }

    $checkpoints | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Balance checkpoints: $($checkpoints.Count) written to $OutputPath" -ForegroundColor Cyan

    # Display
    foreach ($cp in $checkpoints) {
        $window = "$($cp.last_txn_date) → $($cp.next_txn_date) ($($cp.days_since_last_txn) days)"
        Write-Host "  $($cp.checkpoint_date): balance=$$($cp.expected_balance)  gap=$window" -ForegroundColor Green
    }

    return $checkpoints
}
```

### Example Output

```csv
checkpoint_date,days_since_last_txn,last_txn_date,last_txn_desc,next_txn_date,next_txn_desc,expected_balance
2026-05-01,3,2026-04-28,MONTHLY ACCOUNT FEE,2026-05-02,E-TRANSFER DEPOSIT,4245.11
2026-05-05,2,2026-05-03,REINVESTWEALTH,2026-05-06,E-TRANSFER GPA,3890.06
```

### Using Checkpoints

1. Look up the actual bank balance on each `checkpoint_date` (via online banking or statement)
2. Compare against `expected_balance`
3. If they match → Zoho books are correct through that date
4. If they differ → investigate transactions between `last_txn_date` and `next_txn_date`

## Combined Final Report

After both deliverables are generated, produce a final summary:

```powershell
function Write-FinalReconciliationReport {
    param(
        [string]$EntityName,
        [string]$FiscalPeriod,
        [string]$AccountName,
        [int]$TotalTxns,
        [int]$Receiptless,
        [int]$Checkpoints,
        [double]$ZohoEndBalance,
        [double]$BankEndBalance
    )
    $diff = [math]::Round($BankEndBalance - $ZohoEndBalance, 2)
    $report = @"
========================================
RECONCILIATION FINAL REPORT
========================================
Entity:            $EntityName
Period:            $FiscalPeriod
Account:           $AccountName
----------------------------------------
Total transactions: $TotalTxns
Receiptless:       $Receiptless  (see receiptless-transactions.csv)
Balance checkpoints: $Checkpoints (see balance-checkpoints.csv)
Zoho end balance:  $$ZohoEndBalance
Bank end balance:  $$BankEndBalance
Difference:        $diff
Status:            $(if ($diff -eq 0) { "✓ RECONCILED" } elseif ([math]::Abs($diff) -le 10) { "⚠ NEARLY RECONCILED (within $10)" } else { "✗ NEEDS INVESTIGATION" })
========================================
"@
    Write-Host $report -ForegroundColor $(if ($diff -eq 0) { "Green" } elseif ([math]::Abs($diff) -le 10) { "Yellow" } else { "Red" })
    $report | Out-File "reconciliation-final-report.txt" -Encoding UTF8
}
```

## Pipeline Output Files

After running the full pipeline, these output files live in the entity's archive directory:

| File | Contents |
|------|----------|
| `receiptless-transactions.csv` | All reconciled transactions without receipt images |
| `balance-checkpoints.csv` | Bank balance checkpoints at gap dates |
| `reconciliation-final-report.txt` | Final summary per account |
| `*-reconciliation.csv` | Pre-existing reconciliation working file |

## Gotchas

1. **Balance checkpoints require a balance column** in the CSV — if the bank CSV has no running balance, compute it from cumulative debits/credits
2. **Gap day selection** uses the day BEFORE the next transaction — not the middle of the gap — to minimize posting lag interference
3. **Minimum gap threshold:** Only report checkpoints where gap ≥ 2 days to avoid noise from 1-day gaps
4. **Multi-account:** Generate separate checkpoints per bank account
5. **CSV is source of truth** — if Zoho's balance differs from CSV-derived checkpoints, trust the CSV
6. **Posting date lag** (1-5 days) means a checkpoint too close to a transaction may show a temporary mismatch — the gap-day approach avoids this
