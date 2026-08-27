<#
.SYNOPSIS
    Generate reconciliation output reports — receiptless-transactions and balance-checkpoints.

.DESCRIPTION
    Produces the two final deliverables of the bookkeeping pipeline:
    1. Receiptless Transactions Report — all reconciled bank transactions without receipt images
    2. Balance Checkpoints Report — bank balance snapshots at transaction-gap dates for triple-check

    Reads the bank's annual CSV as the source of truth for transaction history and queries
    Zoho for current expense/receipt status via the existing Node.js auth helper.

    Outputs CSV files to the specified output directory.

.PARAMETER Entity
    Entity to report on: "intersite-consulting" or "room-rentals"

.PARAMETER OrgId
    Zoho organization ID (defaults from entity config if not provided)

.PARAMETER AccountId
    Zoho account ID for the bank/credit card account

.PARAMETER CsvPath
    Path to the annual bank portal CSV (source of truth for transactions)

.PARAMETER OutputDir
    Directory to write output CSV files (default: current directory)

.PARAMETER FiscalYearStart
    Start date for the report period (YYYY-MM-DD)

.PARAMETER FiscalYearEnd
    End date for the report period (YYYY-MM-DD)

.PARAMETER AwsProfile
    AWS SSO profile for fetching Zoho secrets from Secrets Manager

.PARAMETER DryRun
    Preview mode — show what would be generated without writing files or calling Zoho API

.EXAMPLE
    .\Invoke-BookkeepingOutputReport.ps1 `
        -Entity "intersite-consulting" `
        -AccountId "93310000000100019" `
        -CsvPath "C:\Users\Victor\intersite-docs\2026 Fiscal Year - Intersite Transactions.csv" `
        -FiscalYearStart "2025-04-01" `
        -FiscalYearEnd "2026-03-31"

.EXAMPLE
    .\Invoke-BookkeepingOutputReport.ps1 -Entity "intersite-consulting" -DryRun
#>

param(
    [ValidateSet("intersite-consulting", "room-rentals")]
    [string]$Entity = "intersite-consulting",
    [string]$OrgId = "",
    [string]$AccountId = "",
    [string]$CsvPath = "",
    [string]$OutputDir = (Get-Location).Path,
    [string]$FiscalYearStart = "",
    [string]$FiscalYearEnd = "",
    [string]$AwsProfile = "intersite",
    [switch]$DryRun
)

#requires -Version 7.0
$ErrorActionPreference = "Stop"

# --- Entity defaults ---
$EntityDefaults = @{
    "intersite-consulting" = @{
        OrgId = "925048093"
        DisplayName = "Intersite Consulting Inc."
        BankAccounts = @(
            @{ Id = "93310000000100019"; Label = "RBC Chequing"; Type = "bank" }
        )
        CreditCardAccounts = @(
            @{ Id = "93310000000100013"; Label = "MC 6258"; Type = "credit_card" }
        )
    }
    "room-rentals" = @{
        OrgId = "925004567"
        DisplayName = "Victor Salmon — Room Rentals"
        BankAccounts = @(
            @{ Id = "TODO"; Label = "TD MLM (needs Zoho account ID)"; Type = "bank" },
            @{ Id = "TODO"; Label = "Scotia TMH (needs Zoho account ID)"; Type = "bank" },
            @{ Id = "TODO"; Label = "RBC Francis (needs Zoho account ID)"; Type = "bank" }
        )
        CreditCardAccounts = @()
    }
}

$cfg = $EntityDefaults[$Entity]
if (-not $OrgId) { $OrgId = $cfg.OrgId }
$DisplayName = $cfg.DisplayName

# --- Validation ---
if (-not $DryRun) {
    if (-not $AccountId -and $cfg.BankAccounts.Count -eq 1) {
        $AccountId = $cfg.BankAccounts[0].Id
    }
    if (-not $AccountId -and $cfg.BankAccounts.Count -gt 1) {
        Write-Warning "Multiple bank accounts for $Entity. Specify -AccountId:"
        foreach ($acct in $cfg.BankAccounts) {
            Write-Warning "  $($acct.Id) — $($acct.Label)"
        }
        return
    }
    if (-not $AccountId) {
        Write-Error "No -AccountId provided and entity has no default. Use -DryRun to preview without API calls."
        return
    }
    if ($AccountId -eq "TODO") {
        Write-Error "AccountId for $Entity is not configured yet. Set -AccountId with the Zoho account ID."
        return
    }
}

$FiscalYearStartStr = if ($FiscalYearStart) { $FiscalYearStart } else { "" }
$FiscalYearEndStr = if ($FiscalYearEnd) { $FiscalYearEnd } else { "" }

Write-Host "=" -f DarkGray * 60
Write-Host "  OUTPUT REPORT: $DisplayName" -f Cyan
Write-Host "=" -f DarkGray * 60
Write-Host "  Zoho Org:      $OrgId"
Write-Host "  Account:       $AccountId"
Write-Host "  CSV:           $(if ($CsvPath) { Split-Path $CsvPath -Leaf } else { '(not provided)' })"
Write-Host "  Output Dir:    $OutputDir"
if ($FiscalYearStartStr) { Write-Host "  Period:        $FiscalYearStartStr → $FiscalYearEndStr" }
Write-Host "  Mode:          $(if ($DryRun) { 'DRY RUN (preview only)' } else { 'LIVE' })" -f $(if ($DryRun) { 'Yellow' } else { 'Green' })
Write-Host ""

# ============================================================================
# DELIVERABLE A: Generate Balance Checkpoints (from CSV, no API needed)
# ============================================================================

function Get-BalanceCheckpoints {
    param([string]$CsvPath, [string]$AccountName)

    if (-not (Test-Path $CsvPath)) {
        Write-Warning "CSV not found: $CsvPath — skipping balance checkpoints"
        return $null
    }

    Write-Host "`n── Balance Checkpoints ──" -f DarkGray

    $lines = Get-Content $CsvPath
    $txns = [System.Collections.Generic.List[pscustomobject]]::new()

    # Auto-detect columns: look at header
    $header = $lines[0]
    $cols = $header -split ','
    $dateCol = 0; $descCol = 1; $debitCol = 2; $creditCol = 3; $balanceCol = -1

    for ($i = 0; $i -lt $cols.Count; $i++) {
        $h = $cols[$i].Trim('" ')
        if ($h -match '(?i)date|transaction') { $dateCol = $i }
        elseif ($h -match '(?i)desc|payee|merchant|name') { $descCol = $i }
        elseif ($h -match '(?i)debit|withdrawal|paid') { $debitCol = $i }
        elseif ($h -match '(?i)credit|deposit') { $creditCol = $i }
        elseif ($h -match '(?i)balance') { $balanceCol = $i }
    }

    $runningBalance = 0.0
    foreach ($line in $lines) {
        if ($line -match '^Account |^"?Date|^Transaction|^$') { continue }
        $parts = $line -split ','
        if ($parts.Count -le [math]::Max($dateCol, $descCol)) { continue }

        $d = Get-Date $parts[$dateCol].Trim('" ') -ErrorAction SilentlyContinue
        if (-not $d) { continue }

        $desc = ($parts[$descCol] -replace '"', '').Trim()
        $debitVal = 0.0; $creditVal = 0.0
        if ($debitCol -ge 0 -and $parts[$debitCol]) { [double]::TryParse(($parts[$debitCol] -replace '[^0-9.-]', ''), [ref]$debitVal) }
        if ($creditCol -ge 0 -and $parts[$creditCol]) { [double]::TryParse(($parts[$creditCol] -replace '[^0-9.-]', ''), [ref]$creditVal) }

        if ($balanceCol -ge 0 -and $parts[$balanceCol]) {
            [double]::TryParse(($parts[$balanceCol] -replace '[^0-9.-]', ''), [ref]$runningBalance)
        } else {
            $runningBalance = $runningBalance - $debitVal + $creditVal
        }

        $txns.Add([pscustomobject]@{ Date = $d; DateStr = $d.ToString('yyyy-MM-dd'); Description = $desc; Balance = [math]::Round($runningBalance, 2) })
    }

    if ($txns.Count -lt 2) {
        Write-Warning "Not enough transactions in CSV to compute checkpoints"
        return $null
    }

    $sorted = $txns | Sort-Object Date
    $checkpoints = [System.Collections.Generic.List[pscustomobject]]::new()

    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $prev = $sorted[$i - 1]
        $curr = $sorted[$i]
        $gapDays = ($curr.Date - $prev.Date).Days
        if ($gapDays -gt 1) {
            $cpDate = $curr.Date.AddDays(-1)
            $checkpoints.Add([pscustomobject]@{
                checkpoint_date     = $cpDate.ToString('yyyy-MM-dd')
                days_since_last_txn = $gapDays
                last_txn_date       = $prev.DateStr
                last_txn_desc       = $prev.Description.Substring(0, [math]::Min(40, $prev.Description.Length))
                next_txn_date       = $curr.DateStr
                next_txn_desc       = $curr.Description.Substring(0, [math]::Min(40, $curr.Description.Length))
                expected_balance    = $prev.Balance
            })
        }
    }

    return $checkpoints
}

# ============================================================================
# DELIVERABLE B: Receiptless Transactions (calls Zoho API)
# ============================================================================

function Get-ReceiptlessTransactions {
    param([string]$OrgId, [string]$AccountId, [string]$Start, [string]$End)

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would query Zoho for reconciled banktransactions and expenses" -f Yellow
        Write-Host "  [DRY RUN] Account: $AccountId, Period: $Start → $End" -f Yellow
        return @()
    }

    Write-Host "`n── Receiptless Transactions ──" -f DarkGray
    Write-Host "  Fetching data from Zoho API..." -f Gray

    # Use Node.js auth helper (same pattern as _snapshot-staleness-check.ps1)
    $secrets = aws secretsmanager get-secret-value `
        --secret-id "Interclaw/FRAD/Provisioning" `
        --profile $AwsProfile `
        --query SecretString `
        --output text 2>$null | ConvertFrom-Json

    if (-not $secrets) {
        Write-Error "Failed to fetch secrets from AWS (profile: $AwsProfile). Run 'aws sso login --profile intersite' first."
        return $null
    }

    $zohoSecrets = @{
        ZOHO_BOOKS_ID = $secrets.ZOHO_BOOKS_ID
        ZOHO_BOOKS_SECRET = $secrets.ZOHO_BOOKS_SECRET
        ZOHO_BOOKS_REFRESH = $secrets.ZOHO_BOOKS_REFRESH
    }
    $env:ZOHO_SECRETS = ($zohoSecrets | ConvertTo-Json -Compress)

    # Inline Node.js script to fetch reconciled transactions + expenses
    $scriptPath = "$PSScriptRoot\_report-query.mjs"
    $dateFilter = ""
    if ($Start -and $End) { $dateFilter = "&date_start=$Start&date_end=$End" }

    $nodeScript = @"
import { ZohoAuth } from 'file:///$($PSScriptRoot.Replace('\','/'))/../zoho/zoho-auth.js';
const ORG_ID = '$OrgId';
const ACCT_ID = '$AccountId';
const DATE_FILTER = '$dateFilter';
async function main() {
  const s = JSON.parse(process.env.ZOHO_SECRETS);
  const a = new ZohoAuth({ clientId: s.ZOHO_BOOKS_ID, clientSecret: s.ZOHO_BOOKS_SECRET, refreshToken: s.ZOHO_BOOKS_REFRESH, stateDir: process.cwd() });
  const token = await a.getToken();
  const headers = { Authorization: 'Zoho-oauthtoken ' + token };

  // Fetch reconciled banktransactions
  let txnPage = 1, txns = [];
  while (true) {
    const u = 'https://www.zohoapis.com/books/v3/banktransactions?organization_id='+ORG_ID+'&status=reconciled&account_id='+ACCT_ID+DATE_FILTER+'&page='+txnPage+'&per_page=200';
    const r = await fetch(u, { headers });
    const d = await r.json();
    if (!d.banktransactions) break;
    txns = txns.concat(d.banktransactions);
    if (!d.page_context?.has_more_page) break;
    txnPage++;
  }

  // Fetch expenses with receipt status
  let expPage = 1, expenses = [];
  while (true) {
    const u = 'https://www.zohoapis.com/books/v3/expenses?organization_id='+ORG_ID+'&paid_through_account_id='+ACCT_ID+DATE_FILTER+'&page='+expPage+'&per_page=200';
    const r = await fetch(u, { headers });
    const d = await r.json();
    if (!d.expenses) break;
    expenses = expenses.concat(d.expenses);
    if (!d.page_context?.has_more_page) break;
    expPage++;
  }

  // Build lookup: transaction_id -> expense with receipt info
  const lookup = {};
  for (const exp of expenses) {
    for (const imp of (exp.imported_transactions || [])) {
      lookup[imp.transaction_id] = {
        expense_id: exp.expense_id,
        has_receipt: !!(exp.has_attachment || exp.expense_receipt_name),
        vendor_name: exp.vendor_name || '',
        amount: exp.amount
      };
    }
  }

  // Find receiptless matched transactions
  const receiptless = txns.filter(t => {
    const m = lookup[t.transaction_id];
    return !m || !m.has_receipt;
  });

  console.log('RECONCILED:' + txns.length);
  console.log('EXPENSES:' + expenses.length);
  console.log('RECEIPTLESS:' + receiptless.length);

  // Output receiptless as JSON for PowerShell to parse
  const output = receiptless.map(t => ({
    transaction_id: t.transaction_id,
    date: t.date,
    amount: t.amount,
    payee: (t.payee || '').trim(),
    account_name: t.account_name || '',
    has_expense: !!lookup[t.transaction_id],
    expense_id: (lookup[t.transaction_id] || {}).expense_id || '',
    has_receipt: !!(lookup[t.transaction_id] || {}).has_receipt,
    reason: lookup[t.transaction_id]
      ? 'Expense exists but no receipt image'
      : 'No matching expense record'
  }));
  process.stdout.write(JSON.stringify(output));
}
main().catch(e => { console.error(e.message); process.exit(1); });
"@

    $nodeScript | Set-Content $scriptPath -Encoding utf8

    $liveOutput = & node $scriptPath 2>&1
    $exitCode = $LASTEXITCODE

    # Parse structured output
    $receiptlessJson = ""
    $lines = $liveOutput -split "`n"
    foreach ($line in $lines) {
        if ($line -match '^RECONCILED:|^EXPENSES:|^RECEIPTLESS:') {
            Write-Host "  $line" -f Gray
        } else {
            $receiptlessJson += $line
        }
    }

    if ($exitCode -ne 0) {
        Write-Error "Zoho API call failed. Run 'aws sso login --profile intersite' and retry."
        return $null
    }

    $result = $receiptlessJson | ConvertFrom-Json
    return $result
}

# ============================================================================
# GENERATE REPORTS
# ============================================================================

# Balance Checkpoints (from CSV — no API needed)
if ($CsvPath) {
    Write-Host "`nGenerating balance checkpoints..." -f Cyan
    $checkpoints = Get-BalanceCheckpoints -CsvPath $CsvPath -AccountName $AccountId

    if ($checkpoints -and $checkpoints.Count -gt 0) {
        $cpPath = Join-Path $OutputDir "balance-checkpoints-$Entity.csv"
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would write $($checkpoints.Count) checkpoints to: $cpPath" -f Yellow
        } else {
            $stamp = @(
                "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
                "# Data source: Balance checkpoints from CSV — $CsvPath",
                "# Entity: $Entity",
                "# Script: Invoke-BookkeepingOutputReport.ps1",
                "#"
            ) -join "`n"
            $stamp, ($checkpoints | ConvertTo-Csv -NoTypeInformation) -join "`n" | Out-File -FilePath $cpPath -Encoding utf8
            Write-Host "  ✅ Wrote $($checkpoints.Count) checkpoints to: $cpPath" -f Green
        }

        Write-Host "  Sample checkpoints:" -f DarkGray
        $checkpoints | Select-Object -First 5 | Format-Table checkpoint_date, days_since_last_txn, expected_balance -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "  ⬜ No checkpoints generated (fewer than 2 transactions or CSV issue)" -f Yellow
    }
} else {
    Write-Host "`nSkipping balance checkpoints — no -CsvPath provided" -f DarkGray
}

# Receiptless Transactions (requires Zoho API)
Write-Host "`nGenerating receiptless transactions report..." -f Cyan
$receiptless = Get-ReceiptlessTransactions -OrgId $OrgId -AccountId $AccountId -Start $FiscalYearStartStr -End $FiscalYearEndStr

if ($receiptless -ne $null) {
    $rlPath = Join-Path $OutputDir "receiptless-transactions-$Entity.csv"
    if ($DryRun) {
        Write-Host "  [DRY RUN] Would write $($receiptless.Count) receiptless transactions to: $rlPath" -f Yellow
    } else {
        $stamp = @(
            "# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
            "# Data source: Receiptless transactions from Zoho — $Entity $FiscalYearStartStr-$FiscalYearEndStr",
            "# Entity: $Entity",
            "# Script: Invoke-BookkeepingOutputReport.ps1",
            "#"
        ) -join "`n"
        $stamp, ($receiptless | ConvertTo-Csv -NoTypeInformation) -join "`n" | Out-File -FilePath $rlPath -Encoding utf8
        Write-Host "  ✅ Wrote $($receiptless.Count) receiptless transactions to: $rlPath" -f Green
    }

    if ($receiptless.Count -gt 0) {
        $noExpense = $receiptless | Where-Object { -not $_.has_expense }
        $noReceipt = $receiptless | Where-Object { $_.has_expense -and -not $_.has_receipt }
        Write-Host "  Without any expense record: $($noExpense.Count)" -f Red
        Write-Host "  Expense exists but no receipt: $($noReceipt.Count)" -f Yellow

        if ($receiptless.Count -le 10) {
            Write-Host "  Detail:" -f DarkGray
            $receiptless | Format-Table date, payee, amount, reason -AutoSize | Out-String | Write-Host
        }
    } else {
        Write-Host "  ✅ All reconciled transactions have receipt images" -f Green
    }
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================
Write-Host ""
# Cleanup temp query file
$queryFile = "$PSScriptRoot\_report-query.mjs"
if (Test-Path $queryFile) { Remove-Item $queryFile -Force }

Write-Host "=" -f DarkGray * 60
Write-Host "  REPORT COMPLETE" -f Cyan
Write-Host "=" -f DarkGray * 60
Write-Host "  Entity:       $DisplayName"
Write-Host "  Account:      $AccountId"
Write-Host "  Output Dir:   $OutputDir"
Write-Host "  Mode:         $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })"
Write-Host ""
