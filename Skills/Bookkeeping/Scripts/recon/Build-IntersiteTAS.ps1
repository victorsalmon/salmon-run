<#
.SYNOPSIS
    Builds the Intersite Consulting TAS CSV.
#>

<#
.SYNOPSIS
    Builds the Intersite Consulting TAS CSV.
#>
#Requires -Version 7.0
param(
    [string]$RootDir = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\intersite-consulting",
    [string]$FiscalYear = "2026",
    [string]$PeriodStart,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RootDir)) { throw "RootDir is required" }
if (-not (Test-Path $RootDir)) { Write-Warning "RootDir not found: $RootDir — TAS generation may fail if paths resolve to missing directories" }

. "$PSScriptRoot\..\shared\Get-EntityConfig.ps1"

$tasPath    = "$RootDir\TAS-$FiscalYear.csv"
$bankDir    = "$RootDir\$FiscalYear Filing\$FiscalYear Bank Statements"
$receiptDir = "$RootDir\$FiscalYear Filing\Receipts"

$entityConfig = (Get-EntityConfig -Entity "intersite-consulting").Entity
$accountDefs = $entityConfig.bank_statement_accounts

$accounts = $accountDefs | ForEach-Object {
    $cutoff = [datetime]::Parse($entityConfig.cutoff_date, [System.Globalization.CultureInfo]::InvariantCulture)
    $startDay = $cutoff.AddDays(1).ToString('yyyy.MM.dd')
    $zohoFile = "$startDay-Present - $($_.label) - Zoho.csv"
    @{
        slug           = $_.slug
        label          = $_.label
        folder         = $_.folder
        raw            = $_.raw_csv
        zoho           = $zohoFile
        manifest       = "_manifest.csv"
        accountFilter  = $_.account_filter
        receiptFolder  = $_.receipt_folder
    }
}

# 
# Load cross-reference data  receipt manifests from _manifest.csv
# 
$receipts = [System.Collections.Generic.Dictionary[string, object]]@{}
$warnings = [System.Collections.ArrayList]@()

# Load _manifest.csv once and index by account then date|amount key
$manPath = "$receiptDir\_manifest.csv"
if (Test-Path $manPath) {
    $allReceipts = Import-Csv $manPath
    foreach ($r in $allReceipts) {
        $dt = if ($r.date) { $r.date } else { "" }
        $amt = if ($r.amount) { $r.amount } else { "" }
        $fn = if ($r.filename) { $r.filename } else { "" }
        $acct = if ($r.account) { $r.account } else { "" }
        if (-not $dt -or -not $fn) { continue }
        if ($acct -in @('_orphans', 'non-matching', '')) { continue }
        try {
            $absAmt = [math]::Abs([decimal]$amt)
        } catch {
            Write-Warning "Skipping manifest row with non-numeric amount '$amt' for $fn"
            continue
        }
        $key = "$dt|$($absAmt.ToString('F2'))"
        if (-not $receipts.ContainsKey($key)) { $receipts[$key] = @{} }
        $receipts[$key][$acct] = $fn
    }
}

# Also index by receipt_folder for resolved paths
$receiptFolders = @{}
foreach ($acct in $accounts) {
    $receiptFolders[$acct.accountFilter] = $acct.receiptFolder
}
# For 'matched' entries without explicit account, will try all accounts

# 
# Receipt match helper  date+amount lookup with account filter
# 
function Find-Receipt($dt, $amt, $accountFilter) {
    $absAmt = [math]::Abs([decimal]$amt)
    $key = "$dt|$([Math]::Round($absAmt, 2).ToString('F2'))"
    if ($receipts.ContainsKey($key)) {
        $entry = $receipts[$key]
        # Determine which account folder to use
        $targetAcct = $accountFilter
        if (-not $targetAcct -or -not $entry.ContainsKey($targetAcct)) {
            # Try 'matched' generic key
            if ($entry.ContainsKey('matched')) {
                $targetAcct = 'matched'
            } else {
                # Fall back to first non-_orphans account
                $nonOrphan = $entry.Keys | Where-Object { $_ -ne '_orphans' -and $_ -ne 'non-matching' } | Select-Object -First 1
                if ($nonOrphan) {
                    $targetAcct = $nonOrphan
                } else {
                    $targetAcct = ($entry.Keys | Select-Object -First 1)
                }
            }
        }
        $fn = $entry[$targetAcct]
        if ($fn) {
            return "Receipts/$($fn -replace '\\', '/')"
        }
    }
    # Fuzzy match: ±3 days, ±$0.10
    $bd = Get-Date $dt
    foreach ($entry in $receipts.GetEnumerator()) {
        $parts = $entry.Key -split '\|'
        $rAmt = [decimal]$parts[1]
        if ([Math]::Round([decimal][math]::Abs($rAmt - $absAmt), 2) -gt [decimal]0.10) { continue }
        $dd = ((Get-Date $parts[0]) - $bd).TotalDays
        if ([math]::Abs($dd) -le 3) {
            $matched = $entry.Value
            $targetAcct = $accountFilter
            if (-not $targetAcct -or -not $matched.ContainsKey($targetAcct)) {
                if ($matched.ContainsKey('matched')) {
                    $targetAcct = 'matched'
                } else {
                    $nonOrphan = $matched.Keys | Where-Object { $_ -ne '_orphans' -and $_ -ne 'non-matching' } | Select-Object -First 1
                    if ($nonOrphan) {
                        $targetAcct = $nonOrphan
                    } else {
                        $targetAcct = ($matched.Keys | Select-Object -First 1)
                    }
                }
            }
            $fn = $matched[$targetAcct]
            if ($fn) {
                return "Receipts/$($fn -replace '\\', '/')"
            }
        }
    }
    return $null
}



# 
# Classification  keyword-based for raw entries, zoho_category from Zoho
# 
$categoryMapping = @(
    # Income
    @{ rx = 'Consulting Revenue';           cat = 'Consulting Revenue' }
    @{ rx = 'WAVE SV9T|WAVE SV\\d+|Wave';   cat = 'Consulting Revenue' }

    # Credit Card Payments (balance sheet transfers, not P&L)
    @{ rx = 'ONLINE\s*BANKING\s*TRANSFER'; cat = 'Credit Card Payments' }
    @{ rx = 'AUTOMATIC\s*PAYMENT|PAYMENT\s*-\s*THANK\s*YOU'; cat = 'Credit Card Payments' }

    # Shareholder Loan (owner transfers)
    @{ rx = 'E.?TRANSFER\s*SENT.*VAS|E.?TRANSFER\s*SENT.*VICTOR'; cat = 'Shareholder Loan' }
    @{ rx = 'E.?TRANSFER\s*AUTODEPOSIT';    cat = 'Shareholder Loan' }

    # Lease Expense
    @{ rx = 'E.?TRANSFER\s*SENT.*AUROMAITREYI'; cat = 'Lease Expense' }
    @{ rx = 'windsor|greene|strata';           cat = 'Lease Expense' }

    # Income Tax Expense
    @{ rx = 'PAD\s*CCRA|CANADA\s*REVENUE|TAX\s*REFUND'; cat = 'Income Tax Expense' }

    # Transfer credits
    @{ rx = 'INTEREST|PURCHASE INTEREST';    cat = 'Credit Card Charges' }
    @{ rx = 'LATE FEE|LATE PAYMENT';         cat = 'Credit Card Charges' }
    @{ rx = 'AUTOMATIC PAYMENT|Misc Payment.*CREDIT'; cat = 'Credit Card Charges' }

    # Bank Fees and Charges
    @{ rx = 'MONTHLY\s*(FEE|ACCOUNT)|PAY-FILE|CHQ\s*RETURN|Monthlyfee|ACCOUNT FEE'; cat = 'Bank Fees and Charges' }
    @{ rx = 'Misc Payment.*FEES|Misc Payment PAY'; cat = 'Bank Fees and Charges' }
    @{ rx = 'Misc Payment Upscale Havens';    cat = 'Bank Fees and Charges' }

    # Professional Fees
    @{ rx = 'LEGALSHIELD';                    cat = 'Professional Fees' }
    @{ rx = 'CIVIL\s*RESOLUTION|BC\s*REGISTR|GOVERNMENT|REGISTRATION'; cat = 'Professional Fees' }
    @{ rx = 'Misc Payment.*DESIGN|Misc Payment.*AUTO|Misc Payment.*INS|Misc Payment.*MISC|Misc Payment.*WAVE CONSULTING'; cat = 'Professional Fees' }

    # Automobile Expense
    @{ rx = 'PETRO\b|SHELL\b|CHEVRON|CHV\d+|GAS\b|CO-OP|CANCO|ESSO|MOBIL(?!E)'; cat = 'Automobile Expense' }
    @{ rx = 'KAL[-\s]*TIRE|LORDCO|IMPARK|PARKING'; cat = 'Automobile Expense' }
    @{ rx = 'ICBC';                            cat = 'Automobile Expense' }
    @{ rx = 'COUNTER|CHEVRON|PETRO|SHELL|ESSO'; cat = 'Automobile Expense' }

    # Software & IT Expenses
    @{ rx = 'INTERSERVER';                     cat = 'Software & IT Expenses' }
    @{ rx = 'FREEDOM MOBILE';                  cat = 'Software & IT Expenses' }
    @{ rx = 'APPSUMO|BOLDSIGN|UDEMY|BITWARDEN|WPFORMS|WP.?FORMS|TIDYCAL|BREEZEDOC'; cat = 'Software & IT Expenses' }
    @{ rx = 'REINVESTWEALTH';                    cat = 'Professional Fees' }
    @{ rx = 'SQSP\*|MOZSEO|P\.SKOOL|MYCLAW';  cat = 'Software & IT Expenses' }
    @{ rx = 'apple\.com|icloud';              cat = 'Software & IT Expenses' }
    @{ rx = 'creative.?fabrica|name.?cheap|anomaly|stripe|openrouter|roomies|github|digitalocean|pixella|google.?fongo|proton|mintlify|linear|supabase|claude|vercel|notion'; cat = 'Software & IT Expenses' }

    # Repairs and Maintenance
    @{ rx = 'THE\s*BUGMAN|VERNON\s*LOCK|OZERTY|SALES\s*DRAFT'; cat = 'Repairs and Maintenance' }
    @{ rx = 'HOME\s*DEPOT|DULUX|VISIONS\s*ELECTRONICS|TEMU|HOME HARDWARE|RONA|CANADIAN TIRE'; cat = 'Repairs and Maintenance' }

    # Office & General Expenses
    @{ rx = 'amazon|AMZN|AMAZON';             cat = 'Office & General Expenses' }
    @{ rx = 'aliexpress|ALIEXPRESS';          cat = 'Office & General Expenses' }
    @{ rx = 'STAPLES|BEST\s*BUY|DOLLARAMA';  cat = 'Office & General Expenses' }
    @{ rx = 'audible|prime video|netflix|spotify'; cat = 'Office & General Expenses' }
    @{ rx = 'battery|CANADIAN TIRE';           cat = 'Office & General Expenses' }

    # Advertising And Marketing
    @{ rx = 'META|FACEBOOK|FB ADS|marketplace listing'; cat = 'Advertising And Marketing' }
    @{ rx = 'COFOODBANK|FOOD\\s*BANK';                   cat = 'Advertising And Marketing' }
    @{ rx = 'CLEAN-IT\\s*ALL';                           cat = 'Repairs and Maintenance' }
)

$exemptCategories = Get-ExemptCategories -Entity "intersite-consulting"

function Classify-Transaction($desc, $amt, $zohoCategory) {
    $descUpper = $desc.ToUpper()
    # If Zoho assigned a specific category (not Other Expenses), use it
    if ($zohoCategory -and $zohoCategory -ne 'Other Expenses') { return $zohoCategory }
    # For Zoho Other Expenses or unclassified, try our keyword patterns first
    foreach ($m in $categoryMapping) {
        if ($descUpper -match $m.rx) { return $m.cat }
    }
    if ($zohoCategory) { return $zohoCategory }
    if ($amt -ge 0) { return 'Consulting Revenue' }
    return 'Other Expenses'
}

# 
# Row builder
# 
$rows = [System.Collections.ArrayList]@()

function Write-Row($Date, $Bank, $Amount, $Description, $Category, $ZohoId, $ReceiptFile, $Source, $SourceFile, $Notes, $ReceiptExempt, $TxType) {
    [void]$rows.Add([PSCustomObject]@{
        date                = $Date
        bank_account        = $Bank
        amount              = $Amount
        description         = $Description
        category            = $Category
        zoho_transaction_id = $ZohoId
        receipt_filename    = $ReceiptFile
        source              = $Source
        source_file         = if ($SourceFile) { $SourceFile } else { "" }
        notes               = $Notes
        receipt_exempt      = if ($ReceiptExempt) { $ReceiptExempt } else { "" }
        transaction_type    = if ($TxType) { $TxType } else { "" }
    })
}

# 
# Central row creation with classification
# 
$script:acctFilterForMakeRow = ""

function Make-Row($dt, $acctLabel, $amt, $fullDesc, $sourceLabel, $sourceFile, $zohoId, $zohoCat, $txType, $receiptFromZoho) {
    $cat = Classify-Transaction $fullDesc $amt $zohoCat

    $notes = ""
    # Prefer Zoho's receipt_filename if present
    if ($receiptFromZoho) {
        $receipt = $receiptFromZoho
    } else {
        $receipt = Find-Receipt $dt $amt $script:acctFilterForMakeRow
    }

    # Determine programmatic exemption reason
    $receiptExempt = ""
    if ($amt -gt 0) {
        $receiptExempt = "Income - no receipt required"
    } elseif ($exemptCategories -contains $cat) {
        $receiptExempt = "Programmatic exemption: $cat"
    }

    Write-Row $dt $acctLabel $amt $fullDesc $cat $zohoId $receipt $sourceLabel $sourceFile $notes $receiptExempt $txType
}

# 
# Zoho dedup key set  populated during Zoho pass, checked during raw pass
# 
$script:zohoKeys = @{}

function Add-ZohoKey($dt, $amt, $acct) {
    $key = "$acct|$dt|$($amt.ToString('F2'))"
    $script:zohoKeys[$key] = $true
}

function Test-ZohoKey($dt, $amt, $acct) {
    $key = "$acct|$dt|$($amt.ToString('F2'))"
    return $script:zohoKeys.ContainsKey($key)
}

# 
# Parse raw fiscal year merge CSVs
# Columns: Account Type,Account Number,Transaction Date,Cheque Number,Description 1,Description 2,CAD$,USD$
# CAD$ positive = inflow (credit), negative = outflow (debit)
# 
function Parse-RawFiscalYear($filePath, $acctLabel, $sourceLabel) {
    $count = 0
    $data = Import-Csv $filePath
    foreach ($row in $data) {
        $dtStr = $row.'Transaction Date'
        if ([string]::IsNullOrWhiteSpace($dtStr)) { continue }
        try {
            $dt = ([DateTime]::Parse($dtStr, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd')
        } catch {
            $dt = $dtStr
        }
        $desc1 = if ($row.'Description 1') { $row.'Description 1' } else { "" }
        $desc2 = if ($row.'Description 2') { $row.'Description 2' } else { "" }
        $fullDesc = "$desc1 $desc2".Trim()
        $cadStr = if ($row.'CAD$') { $row.'CAD$' } else { "" }
        if ([string]::IsNullOrWhiteSpace($cadStr)) { continue }
        $amt = [decimal]$cadStr

        if (Test-ZohoKey $dt $amt $acctLabel) { continue }
        $srcFile = [System.IO.Path]::GetFileName($filePath)
        Make-Row $dt $acctLabel $amt $fullDesc $sourceLabel $srcFile "" "" "" ""
        $count++
    }
    return $count
}

#
# Parse Zoho-Plaid export CSVs
# Format: # comments, then header: date,payee,description,debit_or_credit,amount,zoho_transaction_id,transaction_type,zoho_category,receipt_filename
# Zoho convention: debit = inflow (deposit), credit = outflow (expense/transfer)
# Amount always positive in Zoho  convert to TAS sign: positive = inflow, negative = outflow
# 
function Parse-Zoho($filePath, $acctLabel) {
    $raw = Get-Content -Path $filePath -Raw
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    $lines = $raw -split '\r?\n'
    $count = 0
    $srcFile = [System.IO.Path]::GetFileName($filePath)

    # Build clean CSV (strip comment lines and blank lines) for Import-Csv
    $csvLines = [System.Collections.ArrayList]@()
    $headerPassed = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^#') { continue }
        if (-not $headerPassed) { $headerPassed = $true; [void]$csvLines.Add($trimmed); continue }
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        [void]$csvLines.Add($trimmed)
    }
    if ($csvLines.Count -lt 2) { return 0 }

    $csvText = $csvLines -join "`r`n"
    $data = $csvText | ConvertFrom-Csv

    foreach ($row in $data) {
        $dt = $row.date
        $payee = $row.payee
        $desc = $row.description
        $dc = $row.debit_or_credit
        $amtRaw = $row.amount
        $zohoId = if ($row.zoho_transaction_id) { $row.zoho_transaction_id } else { "" }
        $txType = if ($row.transaction_type) { $row.transaction_type } else { "" }
        $zohoCat = if ($row.zoho_category) { $row.zoho_category } else { "" }
        $receiptFromZoho = if ($row.receipt_filename) { $row.receipt_filename } else { "" }

        if ([string]::IsNullOrWhiteSpace($dt)) { continue }
        if ([string]::IsNullOrWhiteSpace($amtRaw)) { continue }

        # Zoho: debit = inflow  positive, credit = outflow  negative
        $amt = if ($dc -eq "debit" -or $dc -eq "Debit") { [decimal]$amtRaw } else { -[decimal]$amtRaw }
        if ($payee -and $payee -ne $desc) {
            $fullDesc = "$payee  $desc"
        } else {
            $fullDesc = if ($payee) { $payee } else { $desc }
        }

        Add-ZohoKey $dt $amt $acctLabel
        Make-Row $dt $acctLabel $amt $fullDesc $sourceLabel $srcFile $zohoId $zohoCat $txType $receiptFromZoho
        $count++
    }
    return $count
}

# 
# Parse all source files
# Pipeline integrity check - verify source directories
$fatalMissing = @()
if (-not (Test-Path $bankDir)) {
    [void]$fatalMissing.Add("Bank statements directory: $bankDir")
}
if ($accounts.Count -eq 0) {
    [void]$fatalMissing.Add("No bank account definitions from entity config")
}
foreach ($acct in $accounts) {
    $acctDir = "$bankDir\$($acct.folder)"
    if (-not (Test-Path $acctDir)) {
        [void]$fatalMissing.Add("Account directory: $acctDir - $($acct.label)")
    }
}
if ($fatalMissing.Count -gt 0) {
    $msg = "FATAL: Missing critical inputs:`n" + ($fatalMissing -join "`n")
    throw $msg
}
$totalZoho = 0

$zohoDebugCount = 0
foreach ($acct in $accounts) {
    $acctDir = "$bankDir\$($acct.folder)"
    $zohoSpec = $acct.zoho
    if ($zohoSpec.Contains('*') -or $zohoSpec.Contains('?')) {
        $matched = Get-ChildItem "$acctDir\$zohoSpec" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $zohoPath = if ($matched) { $matched.FullName } else { $null }
    } else {
        $zohoPath = "$acctDir\$zohoSpec"
    }
    $label = $acct.label
    $script:acctFilterForMakeRow = $acct.accountFilter

    if ($zohoPath -and (Test-Path $zohoPath)) {
        $sourceLabel = "Zoho:$label"
        $zCount = Parse-Zoho $zohoPath $label
        $totalZoho += $zCount
        if ($zCount -eq 0) {
            [void]$warnings.Add("Zoho export has 0 transactions: $zohoPath  re-run export via Bookkeeper MCP")
        }
    }
}



# Parse raw fiscal year CSVs as a supplementary transaction source.
# Zoho is the canonical source, but the raw CSV captures the complete
# transaction set from the bank portal. The Test-ZohoKey check in
# Parse-RawFiscalYear ensures raw entries that duplicate Zoho ones
# (same date + amount) are skipped — only unique raw entries are added.
$totalRaw = 0
foreach ($acct in $accounts) {
    $rawPath = "$bankDir\$($acct.folder)\$($acct.raw)"
    if (-not (Test-Path $rawPath)) { continue }
    $sourceLabel = "Raw:$($acct.label)"
    $script:acctFilterForMakeRow = $acct.accountFilter
    # Direct inline raw parsing to avoid function scope issues
    $rawCount = 0
    $rawData = Import-Csv $rawPath
    foreach ($rawRow in $rawData) {
        $dtStr = $rawRow.'Transaction Date'
        if ([string]::IsNullOrWhiteSpace($dtStr)) { continue }
        try { $dt = ([DateTime]::Parse($dtStr, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd') } catch { $dt = $dtStr }
        $cadStr = if ($rawRow.'CAD$') { $rawRow.'CAD$' } else { "" }
        if ([string]::IsNullOrWhiteSpace($cadStr)) { continue }
        $amt = [decimal]$cadStr
        if (Test-ZohoKey $dt $amt $acct.label) { continue }
        $desc1 = if ($rawRow.'Description 1') { $rawRow.'Description 1' } else { "" }
        $desc2 = if ($rawRow.'Description 2') { $rawRow.'Description 2' } else { "" }
        $fullDesc = "$desc1 $desc2".Trim()
        $srcFile = [System.IO.Path]::GetFileName($rawPath)
        Make-Row $dt $acct.label $amt $fullDesc $sourceLabel $srcFile "" "" "" ""
        $rawCount++
    }
    $totalRaw += $rawCount
    if ($rawCount -gt 0) {
        [void]$warnings.Add("Raw fiscal year CSV contributed $rawCount unique transactions for $($acct.label)")
    }
}

# 
# Preserve user-set receipt_exempt values from old TAS
# Build lookup of (date|amount|bank_account) -> receipt_exempt from existing TAS
# User-set values override programmatic defaults.
# 
$oldTasPath = "$RootDir\TAS-$FiscalYear.csv"
if (Test-Path $oldTasPath) {
    try {
        $oldRows = Import-Csv $oldTasPath
        $oldExempt = @{}
        foreach ($or in $oldRows) {
            $exemptVal = if ($or.receipt_exempt) { $or.receipt_exempt.Trim() } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($exemptVal)) {
                # Build lookup key matching new row's key
                $lk = "$($or.date)|$($or.amount)|$($or.bank_account)".Trim()
                $oldExempt[$lk] = $exemptVal
            }
        }
        if ($oldExempt.Count -gt 0) {
            foreach ($r in $rows) {
                $lk = "$($r.date)|$($r.amount)|$($r.bank_account)".Trim()
                if ($oldExempt.ContainsKey($lk)) {
                    $r.receipt_exempt = $oldExempt[$lk]
                }
            }
            [void]$warnings.Add("Preserved $($oldExempt.Count) user-set receipt_exempt values from previous TAS")
        }
    } catch {
        [void]$warnings.Add("Could not read previous TAS for exempt preservation: $_")
    }
}

# 
# Preserve zoho_has_receipt from old TAS (prevents receipt_complete_date backsliding)
# Sync-TasReceiptStatus.mjs adds this column; without preservation, every TAS rebuild
# wipes it, causing the status check to lose cloud-side receipt confirmation.
# 
$oldTasPath = "$RootDir\TAS-$FiscalYear.csv"
if (Test-Path $oldTasPath) {
    try {
        $oldRows = Import-Csv $oldTasPath
        $oldReceipt = @{}
        foreach ($or in $oldRows) {
            $hasVal = if ($or.zoho_has_receipt) { $or.zoho_has_receipt.Trim() } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($hasVal)) {
                $lk = "$($or.date)|$($or.amount)|$($or.bank_account)".Trim()
                $oldReceipt[$lk] = $hasVal
            }
        }
        if ($oldReceipt.Count -gt 0) {
            foreach ($r in $rows) {
                $lk = "$($r.date)|$($r.amount)|$($r.bank_account)".Trim()
                if ($oldReceipt.ContainsKey($lk)) {
                    Add-Member -InputObject $r -NotePropertyName 'zoho_has_receipt' -NotePropertyValue $oldReceipt[$lk] -Force
                }
            }
            [void]$warnings.Add("Preserved $($oldReceipt.Count) zoho_has_receipt values from previous TAS")
        }
    } catch {
        [void]$warnings.Add("Could not read previous TAS for zoho_has_receipt preservation: $_")
    }
}

# 
# Backfill descriptions from raw fiscal year CSVs for Zoho rows that lost them
# Zoho's banktransactions API drops descriptions for processed/categorized transactions.
# 
$rawLookup = @{}
foreach ($acct in $accounts) {
    $rawPath = "$bankDir\$($acct.folder)\$($acct.raw)"
    if (-not (Test-Path $rawPath)) { continue }
    $rawData = Import-Csv $rawPath
    $acctLabel = $acct.label
    foreach ($row in $rawData) {
        $dtStr = $row.'Transaction Date'
        if ([string]::IsNullOrWhiteSpace($dtStr)) { continue }
        try { $dt = ([DateTime]::Parse($dtStr, [System.Globalization.CultureInfo]::InvariantCulture)).ToString('yyyy-MM-dd') } catch { $dt = $dtStr }
        $cadStr = if ($row.'CAD$') { $row.'CAD$' } else { "" }
        if ([string]::IsNullOrWhiteSpace($cadStr)) { continue }
        $amt = [decimal]$cadStr
        $desc1 = if ($row.'Description 1') { $row.'Description 1' } else { "" }
        $desc2 = if ($row.'Description 2') { $row.'Description 2' } else { "" }
        $fullDesc = "$desc1 $desc2".Trim()
        $key = "$dt|$($amt.ToString('F2'))|$acctLabel"
        $rawLookup[$key] = $fullDesc
    }
}
$backfilledCount = 0
foreach ($r in $rows) {
    $needsBackfill = [string]::IsNullOrWhiteSpace($r.description) -or @('Shareholder Loan', 'Other Expenses') -contains $r.description.Trim()
    if ($needsBackfill) {
        $amtKey = "{0:F2}" -f [decimal]$r.amount
        $key = "$($r.date)|$amtKey|$($r.bank_account)"
        if ($rawLookup.ContainsKey($key)) {
            $r.description = $rawLookup[$key]
            # Try keyword-based classification with the new description.
            # Preserve original Zoho category only if it's specific, not a generic fallback.
            $keywordCat = Classify-Transaction $r.description $r.amount $null
            $zohoCat = $r.category
            if ($zohoCat -and $zohoCat -notin @('Other Expenses', 'Shareholder Loan', 'Intersite', 'Intersite RBC Business Cash Back Mastercard', 'Consulting Revenue') -and $keywordCat -eq 'Other Expenses') {
                $r.category = $zohoCat
            } else {
                $r.category = $keywordCat
            }
            $backfilledCount++
        }
    }
}
if ($backfilledCount -gt 0) {
    [void]$warnings.Add("Backfilled descriptions from raw CSVs for $backfilledCount Zoho-sourced rows")
}

# 
# Filter out pre-period transactions (before fiscal year start)
# Default: Apr 1 of the year before the fiscal year (Apr 1 - Mar 31 cycle)
# 
if ([string]::IsNullOrWhiteSpace($PeriodStart)) {
    $fy = [int]::Parse($FiscalYear)
    $periodStart = [DateTime]"$($fy - 1)-04-01"
} else {
    $periodStart = [DateTime]::Parse($PeriodStart, [System.Globalization.CultureInfo]::InvariantCulture)
}
$prePeriodCount = 0
$rows = [System.Collections.ArrayList]@($rows | Where-Object {
    $keep = $true
    if ($_.date) {
        try {
            $d = [DateTime]::Parse($_.date, [System.Globalization.CultureInfo]::InvariantCulture)
            if ($d -lt $periodStart) { $keep = $false; $prePeriodCount++ }
        } catch {}
    }
    $keep
})
if ($prePeriodCount -gt 0) {
    [void]$warnings.Add("Filtered out $prePeriodCount pre-period transactions (before $($periodStart.ToString('yyyy-MM-dd')))")
}

#
# Dedup: Three passes.
#
# Pass 1 - Same-date dedup: Zoho's GET /banktransactions returns the same
# underlying transaction on the same date with different transaction_types
# (raw Plaid uncategorized + categorized expense + transfer_fund). When mixed
# types exist, prefer deposit/expense/refund over uncategorized/transfer_fund.
# If all entries share the same type, they are separate real transactions (e.g.
# two $690 deposits on the same day) and all are kept.
#
$sameDayCount = 0
$sameDayDeduped = [System.Collections.ArrayList]@()
$sameDayGroups = $rows | Group-Object { "$($_.date)|$($_.amount.ToString('F2'))|$($_.bank_account)" }
foreach ($g in $sameDayGroups) {
    $entries = $g.Group
    if ($entries.Count -le 1) { [void]$sameDayDeduped.Add($entries[0]); continue }
    $uniqueTypes = ($entries | ForEach-Object { $_.transaction_type } | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    if ($uniqueTypes.Count -le 1) {
        foreach ($e in $entries) { [void]$sameDayDeduped.Add($e) }
    } else {
        $best = $entries | Sort-Object @{Expression = {
            $t = $_.transaction_type
            if ($t -in @('deposit','expense','refund')) { 0 }
            elseif ($t -in @('uncategorized')) { 1 }
            elseif ($t -eq 'transfer_fund') { 2 }
            else { 3 }
        }}, @{Expression = {
            -not [string]::IsNullOrWhiteSpace($_.description) -as [int]
        }} -Descending | Select-Object -First 1
        [void]$sameDayDeduped.Add($best)
        $sameDayCount += ($entries.Count - 1)
    }
}
$rows = $sameDayDeduped
if ($sameDayCount -gt 0) {
    [void]$warnings.Add("Same-date deduplicated $sameDayCount rows (mixed transaction_types, kept deposit/expense/refund)")
}

#
# Pass 2 - Exact dedup: use zoho_transaction_id for Zoho-sourced rows.
# Fall back to date|amount|account for rows without a zoho ID.
#
$dupCount = 0
$zohoDupWarnings = [System.Collections.ArrayList]@()
$seen = @{}
$deduped = [System.Collections.ArrayList]@()
foreach ($r in $rows) {
    $hasZohoId = (-not [string]::IsNullOrWhiteSpace($r.zoho_transaction_id)) -and ($r.source -like 'Zoho:*')
    $key = if ($hasZohoId) { "$($r.zoho_transaction_id)|$($r.bank_account)" } else { "$($r.date)|$($r.amount.ToString('F2'))|$($r.bank_account)" }
    if ($seen.ContainsKey($key)) {
        if ($hasZohoId) {
            # Duplicate zoho_transaction_id — keep both rows and flag for manual review
            $dupKey = $r.zoho_transaction_id
            [void]$zohoDupWarnings.Add("Duplicate zoho_transaction_id: $dupKey on $($r.date) for $($r.bank_account) — kept both rows")
            $r.notes = if ($r.notes) { "$($r.notes); zoho-duplicate" } else { "zoho-duplicate" }
            [void]$deduped.Add($r)
        }
        $dupCount++
    } else { $seen[$key] = $true; [void]$deduped.Add($r) }
}
$rows = $deduped
if ($zohoDupWarnings.Count -gt 0) {
    foreach ($w in $zohoDupWarnings) { [void]$warnings.Add("WARN: $w") }
}
if ($dupCount -gt 0) {
    [void]$warnings.Add("Exact-deduplicated $($dupCount - $zohoDupWarnings.Count) rows (by zoho_id or date|amount|account)")
    if ($zohoDupWarnings.Count -gt 0) {
        [void]$warnings.Add("Kept $($zohoDupWarnings.Count) rows with duplicate zoho_transaction_id — flagged as 'zoho-duplicate' for manual review")
    }
}

#
# Pass 3 - Near-date dedup: same amount within +/-3 days, same account.
# Zoho returns the same banktransaction at initiation date (transfer_fund) and
# posting date (expense). Keep the entry with description (posting-date version).
#
$nearDupCount = 0
$nearDeduped = [System.Collections.ArrayList]@()
$nearGroups = $rows | Group-Object { "$([math]::Abs($_.amount).ToString('F2'))|$($_.bank_account)" }
foreach ($g in $nearGroups) {
    $items = $g.Group | Sort-Object date
    $used = @{}
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($used.ContainsKey($i)) { continue }
        $found = @($i)
        for ($j = $i + 1; $j -lt $items.Count; $j++) {
            if ($used.ContainsKey($j)) { continue }
            $span = [math]::Abs(((Get-Date $items[$i].date) - (Get-Date $items[$j].date)).TotalDays)
            if ($span -gt 0 -and $span -le 3) { $found += $j; $used[$j] = $true; $nearDupCount++ }
        }
        $cluster = $found | ForEach-Object { $items[$_] }
        $best = $cluster | Where-Object { -not [string]::IsNullOrWhiteSpace($_.description) } | Select-Object -First 1
        if (-not $best) { $best = $cluster | Where-Object { $_.category -notmatch 'Intersite' } | Select-Object -First 1 }
        if (-not $best) { $best = $cluster[0] }
        [void]$nearDeduped.Add($best)
    }
}
$rows = $nearDeduped
if ($nearDupCount -gt 0) {
    [void]$warnings.Add("Near-deduplicated $nearDupCount rows (same amount within 3 days, kept entry with description)")
}

# 
# Sort: by bank_account, then date
# 
$rows = $rows | Sort-Object bank_account, date

# 
# Build source file manifest
# 
$manifestLines = [System.Collections.ArrayList]@()
[void]$manifestLines.Add("# Transaction Annual Statement  Intersite Consulting $FiscalYear")
[void]$manifestLines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$manifestLines.Add("# Generator: Skills/Bookkeeping/Scripts/Build-IntersiteTAS.ps1")
[void]$manifestLines.Add("# Total transactions: $($rows.Count)")
[void]$manifestLines.Add("#")
[void]$manifestLines.Add("# Source files:")
foreach ($acct in $accounts) {
    $acctDir = "$bankDir\$($acct.folder)"
    foreach ($kind in @("raw", "zoho")) {
        $fn = $acct.$kind
        if ($fn.Contains('*') -or $fn.Contains('?')) {
            $matched = Get-ChildItem "$acctDir\$fn" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($matched) {
                $fi = $matched
                $hash = (Get-FileHash $fi.FullName -Algorithm SHA256).Hash.Substring(0, 16)
                [void]$manifestLines.Add("#   $($fi.Name)  |  $($fi.Length) bytes  |  $($fi.LastWriteTime.ToString('yyyy-MM-dd'))  |  $hash...")
            }
        } else {
            $fp = "$acctDir\$fn"
            if (Test-Path $fp) {
                $fi = Get-Item $fp
                $hash = (Get-FileHash $fp -Algorithm SHA256).Hash.Substring(0, 16)
                [void]$manifestLines.Add("#   $fn  |  $($fi.Length) bytes  |  $($fi.LastWriteTime.ToString('yyyy-MM-dd'))  |  $hash...")
            }
        }
    }
}
[void]$manifestLines.Add("#")
[void]$manifestLines.Add("# Reference files:")
$manifestPath = "$receiptDir\_manifest.csv"
if (Test-Path $manifestPath) {
    $fi = Get-Item $manifestPath
    [void]$manifestLines.Add("#   _manifest.csv  |  $($fi.Length) bytes  |  $($fi.LastWriteTime.ToString('yyyy-MM-dd'))")
}
if ($warnings.Count -gt 0) {
    [void]$manifestLines.Add("#")
    [void]$manifestLines.Add("# Warnings:")
    foreach ($w in $warnings) { [void]$manifestLines.Add("#   WARN: $w") }
}

# 
# Write output
# 
if ($WhatIf) {
    Write-Host "`n=== TAS-$FiscalYear GENERATION (WHATIF) ===" -ForegroundColor Cyan
    $postZoho = @($rows | Where-Object { $_.source -like 'Zoho:*' }).Count
    Write-Host "Transactions: $($rows.Count)" -ForegroundColor Yellow
    Write-Host "Zoho-sourced: $postZoho" -ForegroundColor Yellow
    Write-Host "Raw-sourced: $($rows.Count - $postZoho)" -ForegroundColor Yellow
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:" -ForegroundColor Red
        foreach ($w in $warnings) { Write-Host "  $w" -ForegroundColor Red }
    }
    $rows | Select-Object date, bank_account, amount, description, category, source | Format-Table -AutoSize
} else {
    $header = $manifestLines -join [Environment]::NewLine
    $csvContent = $rows | ConvertTo-Csv -NoTypeInformation
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tasPath, $header + [Environment]::NewLine + ($csvContent -join [Environment]::NewLine), $utf8NoBom)
    $postZoho = @($rows | Where-Object { $_.source -like 'Zoho:*' }).Count
    Write-Host "TAS written: $tasPath ($($rows.Count) rows)" -ForegroundColor Green
    Write-Host "  Zoho-sourced: $postZoho" -ForegroundColor Green
    Write-Host "  Raw-sourced: $($rows.Count - $postZoho)" -ForegroundColor Green
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "  $w" -ForegroundColor Yellow }
    }
}
