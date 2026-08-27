# Transaction Enrichment — Cleaning, Augmenting, and Classifying Transaction Data

> **Module:** This file is referenced by `tx-categorization/categorize-transactions.md`, `upload/upload-expenses.md`, and `reconcile/reconcile-zoho-monthly.md`. It runs **before** data enters Zoho, ensuring every transaction carries complete, accurate information from all source documents.

## Overview

Every transaction in Zoho must carry the full context from its source documents — the bank statement, the receipt image, and any supporting invoice. This enrichment process ensures that when a CPA reviews the books, every transaction answers: *who, what, when, where, why, and how much.*

**Three types of enrichment:**
1. **Receipt enrichment** — vendor names, dates, amounts from receipt images (existing manifest pipeline)
2. **Income enrichment** — adding client names, invoice references, and service descriptions to incoming payments
3. **Bank transaction enrichment** — adding category labels, payment method, and statement references to all transactions

**Source documents and what they contribute:**

| Source | Data Contributed |
|--------|-----------------|
| Bank statement PDF | Date, amount, payee name, running balance, posting date |
| Receipt image | Vendor, amount, purchase date, payment method, items purchased |
| Invoice (vendor) | Vendor name, invoice number, services description, tax breakdown |
| Bank CSV export | Date, amount, payee, debit/credit indicator, reference number |

All three sources must be reconciled against each other. A transaction where the bank statement says $40.00 to Petro-Canada on Dec 9, the receipt says $35.71 on Dec 7, and the MC statement says $35.71 on Dec 9 — these are the same transaction, with the receipt date being the purchase date and the bank date being the clearing date. The enrichment captures both dates.

## Pipeline Context

Enrichment can run at multiple points:
- **Before upload to Zoho** — prepares receipt manifest data (existing pipeline, `manifest.csv`)
- **During income recording** — when creating deposit entries from bank statement credits
- **During reconciliation** — when matching bank transactions to uploaded expenses

## 1. Vendor Name Normalization

### Business Rules

| Raw Vendor Text | Normalized | Entity | Rationale |
|----------------|------------|--------|-----------|
| `Intersite Consulting Inc.` | `Victor Salmon` | room-rentals | Personal rental income, not corporate |
| `Intersite Consulting` | `Victor Salmon` | room-rentals | Same as above |
| `Intersite Consulting Inc.` | `Intersite Consulting Inc.` | intersite-consulting | Correct as-is for corporate |
| `Amazon.ca`, `Amazon`, `AMAZON` | `Amazon.ca` | either | Standardize |
| `PETRO-CANADA`, `Petro-Canada` | `Petro-Canada` | either | Standardize capitalization |
| `The Home Depot`, `HOME DEPOT` | `Home Depot` | either | Standardize |
| `SUPER SAVE`, `Super Save Gas` | `Super Save Gas` | either | Standardize |
| `KAL TIRE` | `Kal Tire` | either | Standardize |
| `INTERNET LIGHTSPEED`, `Lightspeed` | `Lightspeed Internet` | either | Standardize |
| `DOLLARAMA` | `Dollarama` | either | Standardize capitalization |
| `ESSO 7-Eleven`, `ESSO` | `Esso` | either | Standardize |
| `AliExpress`, `ALIEXPRESS` | `AliExpress` | either | Standardize |

### Procedure

```powershell
function Invoke-VendorNormalization {
    param([string]$RawVendor, [string]$EntitySlug)
    $rules = @{
        "room-rentals" = @{
            "intersite consulting inc." = "Victor Salmon"
            "intersite consulting"      = "Victor Salmon"
        }
        "default" = @{
            "amazon.ca"       = "Amazon.ca"
            "amazon"          = "Amazon.ca"
            "petro-canada"    = "Petro-Canada"
            "petro"           = "Petro-Canada"
            "the home depot"  = "Home Depot"
            "home depot"      = "Home Depot"
            "super save"      = "Super Save Gas"
            "kal tire"        = "Kal Tire"
            "internet lights" = "Lightspeed Internet"
            "lightspeed"      = "Lightspeed Internet"
            "dollarama"       = "Dollarama"
            "esso"            = "Esso"
            "aliexpress"      = "AliExpress"
        }
    }
    $key = $RawVendor.Trim().ToLowerInvariant()
    $lookup = $rules[$EntitySlug] ?? $rules["default"]
    $merged = $rules["default"].Clone()
    if ($rules.ContainsKey($EntitySlug)) {
        foreach ($kv in $rules[$EntitySlug].GetEnumerator()) { $merged[$kv.Key] = $kv.Value }
    }
    return $merged[$key] ?? $RawVendor
}
```

## 2. Date Validation & Correction

### Signals for Wrong Dates

| Signal | Action |
|--------|--------|
| Extracted date differs from file `LastWriteTime` by >30 days | Use file timestamp, log `date_source: file_metadata` |
| Date is year <= 2024 for a 2025+ file | Likely OCR error on old receipt; use file timestamp |
| Date is in the future (> today + 7 days) | Likely wrong; flag for manual review |
| Date is empty/null | Extract from filename pattern or use file timestamp |
| `date_on_receipt` differs from `date_photo_taken` | Keep both in sidecar JSON |

### Procedure

```powershell
function Resolve-ReceiptDate {
    param([string]$ExtractedDate, [datetime]$FileLastWrite, [string]$Filename)
    $parsedDate = $null
    if ($ExtractedDate -match '\d{4}-\d{2}-\d{2}') {
        $parsedDate = Get-Date $Matches[0] -ErrorAction SilentlyContinue
    }
    # Check filename for date patterns
    $filenameDate = $null
    if ($Filename -match '(\d{4}-\d{2}-\d{2})') {
        $filenameDate = Get-Date $Matches[1] -ErrorAction SilentlyContinue
    }
    if (-not $parsedDate -and $filenameDate) { return $filenameDate.ToString("yyyy-MM-dd") }
    if (-not $parsedDate -and $FileLastWrite) { return $FileLastWrite.ToString("yyyy-MM-dd") }
    if ($parsedDate -and $FileLastWrite) {
        $diff = [math]::Abs(($parsedDate - $FileLastWrite).TotalDays)
        if ($diff -gt 30) {
            Write-Warning "Date discrepancy: extracted=$ExtractedDate vs file=$($FileLastWrite.ToString('yyyy-MM-dd')) — using file timestamp"
            return $FileLastWrite.ToString("yyyy-MM-dd")
        }
    }
    return $parsedDate.ToString("yyyy-MM-dd")
}
```

## 3. Amount Validation

### Edge Cases

| Scenario | Handling |
|----------|----------|
| `$0.00` on multi-page PDF page > 1 | Mark `informational: true`, skip as expense |
| Negative amount (e.g. `-11.30`) | Preserve as valid refund, flag `type: refund` |
| `Infinity` in JSON | Pipeline sanitizer replaces with `0` — flag for review |
| Amount > `$500` | Flag for manual review (per business rules) |
| Amount missing/empty | Skip (no expense to create) |

### Procedure

```powershell
function Test-ValidAmount {
    param([double]$Amount, [string]$Notes, [hashtable]$Sidecar)
    if ($Amount -eq 0) {
        $sidecarPage = $Sidecar.page_number
        if ($sidecarPage -gt 1 -and $Notes -match 'merged|page') {
            return @{ Valid = $false; Reason = "Informational page $sidecarPage"; Skip = $true }
        }
        return @{ Valid = $false; Reason = "Zero amount"; Skip = $true }
    }
    if ($Amount -lt 0) {
        return @{ Valid = $true; Type = "refund"; Skip = $false }
    }
    if ($Amount -gt 500) {
        return @{ Valid = $true; Flag = "manual-review"; Reason = "Amount > $500"; Skip = $false }
    }
    return @{ Valid = $true; Skip = $false }
}
```

## 4. Description Augmentation

### Rules

| Source | Description Strategy |
|--------|---------------------|
| Vendor + amount | `"{Vendor} — ${Amount}"` |
| Notes available | Use notes, append vendor |
| Multi-page PDF | `"{Vendor} — ${Amount} (merged {N} pages)"` |
| Refund | `"Refund — {Vendor} — ${Amount}"` |
| Model refusal | `"Receipt: {filename} — manual review needed"` |

```powershell
function Build-Description {
    param([string]$Vendor, [double]$Amount, [string]$Notes, [int]$PageCount)
    if ($Amount -lt 0) { return "Refund — $Vendor — ${Amount}" }
    if ($Notes) { return "$Notes — $Vendor" }
    if ($PageCount -gt 1) { return "$Vendor — ${Amount} (merged $PageCount pages)" }
    return "$Vendor — ${Amount}"
}
```

## 5. Income Classification (New)

### Overview

When bank statement credits appear in the chequing account (Online Banking transfers, direct deposits, CRA payments), they must be recorded as income — NOT left as uncategorized bank transactions. For each credit, create a `deposit` transaction that links the income account to the bank account.

### Income Source Mapping

| Bank Statement Description | Income Account | Zoho Account ID | Notes |
|---------------------------|---------------|-----------------|-------|
| Online Banking transfer - XXXX | Consulting Revenue | `93310000000149102` | Client payments for services |
| PAD CCRA CANADA | [2680] Taxes Payable GST | `93310000000129094` | CRA tax refunds/remittances |
| e-Transfer received | Shareholder Loan | `93310000000146154` | Owner contributions |
| Interest (bank) | Interest Income | system account | Bank interest earned |

### Procedure

For each credit transaction that represents income:

```powershell
$body = @{
    from_account_id = "93310000000149102"    # Consulting Revenue (source)
    to_account_id    = "93310000000100019"    # RBC chequing (destination)
    transaction_type = "deposit"
    amount          = $bankTxn.amount
    date            = $bankTxn.date
    description     = "$($bankTxn.payee) — client payment"
} | ConvertTo-Json -Compress

Invoke-RestMethod -Uri "https://www.zohoapis.com/books/v3/banktransactions?organization_id=$orgId" `
  -Method POST -Headers $headers -Body $body
```

### Classification Rules

**Is this income?** A credit transaction is income if:
- It represents money earned from clients/contracts (Online Banking transfers from known client names)
- It's a government refund (CRA, provincial)
- It's bank interest

**Is this NOT income?** A credit transaction is NOT income if:
- It's a bank fee refund/reversal
- It's an internal transfer between your own accounts
- It's a credit card payment from the chequing account (those are debit transactions elsewhere)
- It's an e-Transfer you sent to yourself (shareholder loan movement)

**Enrichment details to include in income transactions:**
- Client name (from bank payee or invoice reference)
- Service description (from invoice or contract)
- Invoice number (if invoiced through Zoho)
- Payment method (Online Banking, e-Transfer, etc.)
- GST/HST portion (if applicable)

## 5b. Category Assignment (Cross-Reference — Receipt/Expense Side)

Use the vendor → category mappings from these authoritative sources, checked in order:

1. **`Plugins/clock-lobster-books/account/categorize-income/SKILL.md`** — income classification (including rental income patterns and situations catalog)
2. **`Plugins/clock-lobster-books/account/categorize-expenses/SKILL.md`** — expense classification for all entities
3. **`tx-categorization/categorization-rules.json`** — Complete keyword→account mapping (both Room Rentals and Intersite account IDs)
4. **Categorization rules** — Entity-specific overrides in `tx-categorization/`

### Entity-Based Default Categories

| Entity | Default Expense Account | Zoho Account ID |
|--------|------------------------|-----------------|
| room-rentals | Other Expenses | `151803000000000460` |
| intersite-consulting | Consultant Expense | `151803000000000454` |

## 6. Bank Transaction Enrichment During Reconciliation

During reconciliation, each bank statement transaction should carry these enriched fields:

| Field | Source | Enriched Value |
|-------|--------|---------------|
| `payee` | Bank statement | Normalized vendor name from receipt |
| `description` | Bank CSV / receipt | `"{Vendor} — {amount} — {items}"` |
| `reference_number` | Bank statement | Original statement reference |
| `payment_mode` | Receipt | `Visa`, `MC`, `Online Banking`, `Cash` |
| `statement_date` | Bank statement PDF | The statement period date (not posting date) |

### Linking Receipts to Bank Transactions

**Correct workflow (Plaid):**
1. Plaid creates the bank transaction automatically
2. In Zoho UI, find the transaction → click to open → attach the receipt image
3. The receipt becomes part of the transaction record

**Fallback workflow (CSV import):**
1. Import bank statement CSV via `POST /bankstatements`
2. Upload expense with receipt via `POST /expenses`
3. Match during reconciliation: `POST /banktransactions/{id}/match`

## 7. Pipeline Integration

Run enrichment as a standalone pass after extraction completes:

```powershell
# One-time enrichment of a Complete/ directory
$manifest = Import-Csv "Complete/manifest.csv"
foreach ($row in $manifest) {
    $vendor = Invoke-VendorNormalization -RawVendor $row.vendor -EntitySlug $entity
    $date = Resolve-ReceiptDate -ExtractedDate $row.date -FileLastWrite (Get-Item "Complete/$($row.filename)").LastWriteTime -Filename $row.filename
    $amountValidation = Test-ValidAmount -Amount ([double]$row.amount) -Notes $row.notes
    $description = Build-Description -Vendor $vendor -Amount ([double]$row.amount) -Notes $row.notes
    # Write enriched row to a new manifest or update in place
}
```

## 8. Known Failure Modes

| Failure | Sign | Action |
|---------|------|--------|
| Model refused to analyze | `vendor: "Model Refusal"` | Re-prompt with minimal schema; if still fails, move to Errors/ |
| Image too small | Most fields null | Re-render PDF at 300 DPI, retry |
| Conflicting values across PDF pages | Different vendors per page | Composite merge: page with most non-null fields wins |
| Colliding filenames | Two receipts produce same `image_filename` | `Resolve-FilenameCollision`: add receipt_number, datetime expansion, or numeric suffix |
