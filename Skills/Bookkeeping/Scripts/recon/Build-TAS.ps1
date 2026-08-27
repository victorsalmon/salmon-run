<#
.SYNOPSIS
    Builds the TAS CSV for room rentals.
#>

<#
.SYNOPSIS
    Builds the Transaction Annual Statement (TAS) CSV for room rentals.
#>
<#
.SYNOPSIS
    Builds the Room Rentals TAS-2026.csv by merging raw bank CSVs with Zoho-Plaid exports.
.DESCRIPTION
    Cross-references the rent register and damage-deposit ledger, performs cross-account transfer matching,
    and outputs a TAS file with a SHA256-verified source manifest.
.PARAMETER RootDir
    Root directory containing the room-rentals bookkeeping files.
.PARAMETER WhatIf
    Show what would be done without making changes.
.EXAMPLE
    .\Build-TAS.ps1
    .\Build-TAS.ps1 -WhatIf
#>
#Requires -Version 7.0
param(
    [string]$RootDir = "C:\Repos\intersite-docs\Taxes and Bookkeeping\room-rentals",
    [int]$FiscalYear = 2026,
    [string]$CutoffDate,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

if ($FiscalYear -notmatch '^\d{4}$') { throw "Invalid fiscal year: '$FiscalYear' — must be a 4-digit year" }

if ([string]::IsNullOrWhiteSpace($RootDir)) { throw "RootDir is required" }
if (-not (Test-Path $RootDir)) { Write-Warning "RootDir not found: $RootDir — TAS generation may fail if paths resolve to missing directories" }

. (Join-Path $PSScriptRoot ".." "shared" "Get-EntityConfig.ps1")

$tasPath    = "$RootDir\TAS-$FiscalYear.csv"
$regPath    = "$RootDir\rent-register.csv"
$ddPath     = "$RootDir\damage-deposit-ledger-$FiscalYear.csv"
$manPath    = "$RootDir\$FiscalYear Receipts\manifest-enriched.csv"

$bankDir = "$RootDir\$FiscalYear Bank Statements"

$entityConfig = (Get-EntityConfig -Entity "room-rentals").Entity
$accountDefs = $entityConfig.bank_statement_accounts

if ([string]::IsNullOrWhiteSpace($CutoffDate)) {
    $cutoffRaw = $entityConfig.cutoff_date
    if ($cutoffRaw -match '^\d{4}-(\d{2})-(\d{2})$') {
        $CutoffDate = '{0}.{1}' -f $Matches[1], $Matches[2]
    } else {
        throw "Entity config cutoff_date is not in yyyy-MM-dd format: '$cutoffRaw'"
    }
}
if ($CutoffDate -notmatch '^\d{1,2}\.\d{2}$') {
    throw "Invalid CutoffDate format: '$CutoffDate' — expected M.dd or MM.dd (e.g. '6.10' or '06.10')"
}

$accounts = $accountDefs | ForEach-Object {
    @{
        slug      = $_.slug
        label     = $_.label
        folder    = $_.folder
        raw       = $_.raw_csv
        zoho      = "$FiscalYear.$CutoffDate-Present - $($_.label) - Zoho.csv"
        rawCutoff = $_.raw_cutoff
    }
}

$crossRefAccounts = $accountDefs | ForEach-Object {
    @{
        slug   = $_.slug
        folder = $_.folder
        raw    = $_.raw_csv
    }
}

# 
# Load cross-reference data
# 
$register = @{}; $ddLedger = @{}; $receipts = @{}; $crossRefCredits = @{}
$warnings = [System.Collections.ArrayList]@()
$totalRawRows = 0; $totalZohoRows = 0

if (Test-Path $regPath) {
    Import-Csv $regPath | ForEach-Object { $register["$($_.room_id)|$($_.payment_date)|$($_.amount)"] = $_ }
}
if (Test-Path $ddPath) {
    Import-Csv $ddPath | ForEach-Object { $ddLedger["$($_.room_id)|$($_.payment_date)|$($_.amount)"] = $_ }
}
if (Test-Path $manPath) {
    Import-Csv $manPath | ForEach-Object { 
        if ($_.date -and $_.amount) {
            $amt = "{0:F2}" -f [math]::Round([decimal]$_.amount, 2)
            $key = "$($_.date)|$amt"
            $receipts[$key] = $_
            $ref = if ($_.zoho_transaction_id) { $_.zoho_transaction_id } elseif ($_.bank_reference) { $_.bank_reference } else { "" }
            if ($ref) {
                $refKey = "$key|$ref"
                $receipts[$refKey] = $_
            }
        }
    }
}

# Load cross-reference account CSVs for Transfer Out matching
foreach ($xref in $crossRefAccounts) {
    $xrefPath = "$bankDir\$($xref.folder)\$($xref.raw)"
    if (Test-Path $xrefPath) {
        Import-Csv $xrefPath | ForEach-Object {
            $amt = [double]$_."CAD$"
            if ($amt -gt 0) {  # Credits only
                $dt = $_."Transaction Date"
                $desc = "$($_."Description 1") $($_."Description 2")".Trim()
                $xrefSlug = $xref.slug
                $key = "$([math]::Round($amt, 2))|$xrefSlug"
                if (-not $crossRefCredits.ContainsKey($key)) { $crossRefCredits[$key] = @() }
                $crossRefCredits[$key] += @{ date = $dt; description = $desc; slug = $xrefSlug }
            }
        }
    }
}

# 
# Match helpers  date-window matching (5 days by amount)
# 
function Match-Register($dt, $amt) {
    $bd = Get-Date $dt
    foreach ($key in $register.Keys) {
        $parts = $key -split '\|'
        if ([math]::Abs([double]$parts[2] - $amt) -ge 0.1) { continue }
        $dd = ((Get-Date $parts[1]) - $bd).TotalDays
        if ([math]::Abs($dd) -le 5) { return $register[$key] }
    }
    return $null
}

function Match-DD($dt, $amt) {
    $bd = Get-Date $dt
    foreach ($key in $ddLedger.Keys) {
        $parts = $key -split '\|'
        if ([math]::Abs([double]$parts[2] - $amt) -ge 0.1) { continue }
        $dd = ((Get-Date $parts[1]) - $bd).TotalDays
        if ([math]::Abs($dd) -le 5) { return $ddLedger[$key] }
    }
    return $null
}

# 
# Cross-account matching for ONLINE BANKING TRANSFER entries
# When a Transfer Out debit amount matches a credit on another account
# within ±3 days, it is a credit card payment, not an unknown transfer.
# 
function Resolve-TransferOutMatch($dt, $amt) {
    # Use absolute value - the debit is negative but cross-reference credits are positive
    $positive = [math]::Abs($amt)
    $rounded = [math]::Round($positive, 2)
    $bd = Get-Date $dt
    $xrefSlugs = $crossRefAccounts | ForEach-Object { $_.slug }
    foreach ($xrefSlug in $xrefSlugs) {
        $key = "$rounded|$xrefSlug"
        if ($crossRefCredits.ContainsKey($key)) {
            foreach ($entry in $crossRefCredits[$key]) {
                $ed = Get-Date $entry.date
                $dd = ($ed - $bd).TotalDays
                if ([math]::Abs($dd) -le 3) {
                    return @{ matched = $true; target = $xrefSlug; description = $entry.description }
                }
            }
        }
    }
    return @{ matched = $false }
}

function Classify-Debit($desc, $acctLabel) {
    $room = $null
    $mapping = @(
        @{ rx = 'mortgage';     cat = 'Mortgage' }
        @{ rx = 'Strata|AdvantageStrata|FEES/DUES NW';  cat = 'Strata Fees' }
        @{ rx = 'HYDRO|B\.C\. HYDRO';  cat = 'Utility' }
        @{ rx = 'LIGHTS|INTERNET';  cat = 'Internet' }
        @{ rx = 'LN PYMT';      cat = 'Loan Payment' }
        @{ rx = 'TAX|PROPERTY TAX|ABBOTSFORD CITY|ABBTSFRD'; cat = 'Property Tax' }
        @{ rx = 'INSURANCE|TD Ins'; cat = 'Insurance' }
        @{ rx = 'NETFLIX';      cat = 'Subscription' }
        @{ rx = 'FACEBK|META|FB'; cat = 'Advertising' }
        @{ rx = 'AMZN|Amazon';  cat = 'Supplies' }
        @{ rx = 'HOME DEPOT|THE HOME DEPOT'; cat = 'Repairs' }
        @{ rx = 'KAL-TIRE|PETRO|SHELL|SUPER SAVE|COINAMATIC|BCAA|BUZZLY|ARMSTRONG|CANCO|XYQMLY|CHEVRON'; cat = 'Vehicle/Other' }
            @{ rx = 'MONTHLY (ACCOUNT )?FEE|WITHDRAWAL FEES?|CHQ RETURN|OVERDRAFT|SERVICE CHARGE|ACCT FEE REBATE'; cat = 'Bank Fee' }
            @{ rx = 'REINVESTWEALTH|LawDepot'; cat = 'Professional Services' }
            @{ rx = 'WAVE PRO|ROOMIES|aliexpress|COURT|InterServer'; cat = 'Service Fee' }
        @{ rx = 'MISC PAYMENT INTERSITE|INTERSITE CONSU'; cat = 'Management Fee' }
        @{ rx = 'MISC PAYMENT.*CREDIT CARD|CREDIT CARD|RBC ION Visa'; cat = 'Credit Card Payment' }
            @{ rx = 'ONLINE BANKING TRANSFER'; cat = 'Transfer Out' }
        @{ rx = 'DEPOSIT FREE INTERAC|E-TFR .* EPAY|E-TRANSFER \*\*\*'; cat = 'Owner Funding' }
        @{ rx = 'e-Transfer.Autodeposit|e-Transfer - Autodeposit'; cat = 'Owner Funding' }
        @{ rx = 'FRA RBC Day to Day Banking'; cat = 'Credit Card Payment' }
        @{ rx = 'IKEA'; cat = 'Supplies' }
        @{ rx = 'PURCHASE INTEREST'; cat = 'Credit Card Charges' }
        @{ rx = 'AUTOMATIC PAYMENT.*THANK|PAYMENT - THANK'; cat = 'Credit Card Payment' }
        @{ rx = 'CHV43079'; cat = 'Vehicle/Other' }
        @{ rx = '54YR57N'; cat = 'Mortgage' }
        @{ rx = 'ANOMALY|ANOMA'; cat = 'Service Fee' }
    )
    foreach ($m in $mapping) {
        if ($desc -match $m.rx) { return $m.cat, $room }
    }
    return 'Expense', $room
}

# 
# Row builder
# 
$rows = [System.Collections.ArrayList]@()
$sourcesUsed = @()

$exemptCategories = Get-ExemptCategories -Entity "room-rentals"

function Write-Row($Date, $Bank, $Amount, $Description, $Category, $RoomId, $Tenant, $Period, $RegisterRef, $DdRef, $ReceiptFile, $ZohoId, $Source, $Notes, $ReceiptExempt) {
    [void]$rows.Add([PSCustomObject]@{
        date              = $Date
        bank_account      = $Bank
        amount            = $Amount
        description       = $Description
        category          = $Category
        room_id           = $RoomId
        tenant            = $Tenant
        occupancy_period  = $Period
        register_ref      = $RegisterRef
        dd_ref            = $DdRef
        receipt_filename  = $ReceiptFile
        zoho_transaction_id = $ZohoId
        source            = $Source
        notes             = $Notes
        receipt_exempt    = if ($ReceiptExempt) { $ReceiptExempt } else { "" }
    })
}

# 
# Parse raw bank CSVs (direct from bank, Jan 1  Jun 10)
# 
function Parse-RawScotia($filePath, $acctLabel) {
    $lines = Get-Content $filePath
    for ($i = 2; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^("",)+""$') { continue }
        if ($line -notmatch '^"","(\d{4}-\d{2}-\d{2})"') { continue }
        $f = $line -split '","' | ForEach-Object { $_.Trim('"') }
        if ($f.Count -lt 7) { continue }

        $dt = $f[1]; $desc = $f[2]; $sub = $f[3]; $type = $f[4]
        $amt = if ($type -eq "Credit") { [double]$f[5] } else { -[double]($f[5].TrimStart('-')) }
        $rec = if ($f.Count -gt 7) { $f[7] } else { "" }
        Make-Row $dt $acctLabel $amt "$desc $sub".Trim() $type $rec "" $sourceLabel
    }
}

function Parse-RawTD($filePath, $acctLabel) {
    $rawData = Import-Csv $filePath
    foreach ($row in $rawData) {
        if ([string]::IsNullOrWhiteSpace($row.Date)) { continue }
        $dt = $row.Date; $desc = $row.Description; $rec = $row.receipt_filename
        $amt = 0; $type = $null
        if (-not [string]::IsNullOrWhiteSpace($row.Credit)) { $amt = [double]$row.Credit; $type = "Credit" }
        elseif (-not [string]::IsNullOrWhiteSpace($row.Debit)) { $amt = -[double]$row.Debit; $type = "Debit" }
        else { continue }
        Make-Row $dt $acctLabel $amt $desc $type $rec "" $sourceLabel
    }
}

function Parse-RawRBC($filePath, $acctLabel) {
    $rawData = Import-Csv $filePath
    foreach ($row in $rawData) {
        if ([string]::IsNullOrWhiteSpace($row.'Transaction Date')) { continue }
        $dt = $row.'Transaction Date'; $desc1 = $row.'Description 1'; $desc2 = $row.'Description 2'
        $amt = [double]$row.'CAD$'; $rec = $row.receipt_filename
        $type = if ($amt -gt 0) { "Credit" } else { "Debit" }
        $fullDesc = "$desc1 $desc2".Trim()
        Make-Row $dt $acctLabel $amt $fullDesc $type $rec "" $sourceLabel
    }
}

# 
# Parse Zoho-Plaid export CSVs (Jun 11  present, with zoho_transaction_id)
# Format: # comments, then header: date,payee,description,debit_or_credit,amount,zoho_transaction_id,...
# 
function Parse-Zoho($filePath, $acctLabel) {
    $cutoff = $global:zohoCutoffDate
    $lines = Get-Content $filePath
    $started = $false; $header = $null
    $count = 0
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^#') { continue }
        if (-not $started) { $started = $true; $header = $trimmed; continue }
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $f = $trimmed -split ','
        if ($f.Count -lt 5) { continue }

        $dt = $f[0]; $payee = $f[1]; $desc = $f[2]; $dc = $f[3]; $amtRaw = $f[4]
        $zohoId = if ($f.Count -gt 5) { $f[5] } else { "" }
        $txType = if ($f.Count -gt 6) { $f[6] } else { "" }
        $zohoCat = if ($f.Count -gt 7) { $f[7] } else { "" }

        # Skip Zoho entries within the raw CSV date range - raw is authoritative
        if ($cutoff -and $dt -match '^(\d{4})-(\d{2})-(\d{2})$') {
            try {
                $dtObj = Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3]
                $cutoffObj = Get-Date -Year $cutoff.Substring(0,4) -Month $cutoff.Substring(5,2) -Day $cutoff.Substring(8,2)
                if ($dtObj -le $cutoffObj) { continue }
            } catch { }
        }

        # Zoho export flips debit/credit convention (debit=money in, credit=money out).
        # Swap: treat Zoho "debit" as credit (positive) and Zoho "credit" as debit (negative).
        $amt = if ($dc -eq "debit" -or $dc -eq "Debit") { [double]$amtRaw } else { -[double]$amtRaw }
        $fullDesc = if ($payee) { "$payee  $desc".Trim() } elseif ($desc) { $desc } else { $zohoCat }
        $rec = ""

        Make-Row $dt $acctLabel $amt $fullDesc $dc $rec $zohoId $sourceLabel
        $count++
    }
    return $count
}

# 
# Central classification and row-creation
# 
function Make-Row($dt, $acctLabel, $amt, $fullDesc, $type, $rec, $zohoId, $sourceLabel) {
    if (Dedup-Key $dt $amt $fullDesc $sourceLabel $acctLabel) { return }
    $cat = "Other"; $room = $null; $tenant = $null; $period = $null; $regRef = $null; $ddRef = $null
    $isCredit = ($type -eq "Credit" -or $type -eq "credit" -or $amt -gt 0)

    if ($isCredit) {
        $entry = Match-Register $dt $amt
        if ($entry) {
            if ($entry.paid_for_month -eq "DD") {
                $cat = "Damage Deposit"; $room = $entry.room_id
                $regRef = "$($entry.room_id)/DD"; $tenant = $entry.notes
            } else {
                $cat = "Rent"; $room = $entry.room_id; $period = $entry.paid_for_month
                $regRef = "$($entry.room_id)/$($entry.paid_for_month)"; $tenant = $entry.notes
            }
        } else {
            $entry = Match-DD $dt $amt
            if ($entry) {
                $cat = "Damage Deposit"; $room = $entry.room_id; $tenant = $entry.tenant_name
                $ddRef = $entry.tenant_name
                if ($entry.type -eq "refund") { $cat = "Damage Deposit Refund"; $amt = -$amt }
            } else {
                $cat = "Owner Funding"
                if ($fullDesc -match "LawDepot|REINVESTWEALTH") { $cat = "Other Income" }
                if ($fullDesc -match "Amazon|Amzn|correction.*Amazon|AMZN Mktp") { $cat = "Supplies" }
                if ($fullDesc -match "ACCT FEE REBATE") { $cat = "Bank Fee" }
                if ($fullDesc -match "FRA RBC Day to Day Banking") { $cat = "Credit Card Payment" }
                if ($fullDesc -match "RBC ION Visa") { $cat = "Credit Card Payment" }
                if ($fullDesc -match "IKEA") { $cat = "Supplies" }
                if ($fullDesc -match "PURCHASE INTEREST") { $cat = "Credit Card Charges" }
            }
        }
    } else {
        $cat, $room = Classify-Debit $fullDesc $acctLabel
        # Property-specific room assignment
        if (-not $room) {
            if ($acctLabel -match "SCOTIA") { $room = "TMH" }
            elseif ($acctLabel -match "TD-MLM") { $room = "MLM" }
            elseif ($acctLabel -match "RBC-FRA") { $room = "FRA" }
        }
        # Override: large round transfers from Scotia/RBC to other accounts are owner funding
        if ($fullDesc -match "E-TRANSFER SENT VICTOR|withdrawal.*Free Interac") { $cat = "Owner Funding" }
        # Override: Scotia $994 is Shawntell DD refund (in DD ledger)
        if ($fullDesc -match "withdrawal" -and [math]::Abs($amt) -eq 994) { $cat = "Damage Deposit Refund" }
        # Override: TD SEND E-TFR $475 and $50 are Zachary DD items (in DD ledger)
        if ($fullDesc -match "SEND E-TFR" -and ([math]::Abs($amt) -eq 475 -or [math]::Abs($amt) -eq 50)) { $cat = "Damage Deposit"; $room = "MLM" }
    }

    # Auto-match receipt from manifest if not already linked
    if (-not $rec -and $receipts.Count -gt 0) {
        # Normalize date to YYYY-MM-DD for matching against manifest
        $normDt = ConvertTo-IsoDate $dt
        $roundedAmt = "{0:F2}" -f [math]::Round([math]::Abs($amt), 2)
        # Try date+amount+ref first if a reference is available (zoho_transaction_id from Zoho export)
        if ($zohoId) {
            $refKey = "$normDt|$roundedAmt|$zohoId"
            if ($receipts.ContainsKey($refKey)) {
                $matched = $receipts[$refKey]
                $rec = $matched.filename
            }
        }
        # Fall back to date+amount
        if (-not $rec) {
            $matchKey = "$normDt|$roundedAmt"
            if ($receipts.ContainsKey($matchKey)) {
                $matched = $receipts[$matchKey]
                $rec = $matched.filename
            }
        }
        # Fallback: ±2 days for all transactions (bank posting date ≠ receipt date)  # weekend-safe: Sat invoice posts Mon
        if (-not $rec) {
            $dtObj = if ($normDt -match '^(\d{4})-(\d{2})-(\d{2})$') {
                Get-Date -Year $Matches[1] -Month $Matches[2] -Day $Matches[3]
            }
            if ($dtObj) {
                foreach ($offset in @(1, -1, 2, -2)) {
                    $altDt = $dtObj.AddDays($offset).ToString('yyyy-MM-dd')
                    $altKey = "$altDt|$roundedAmt"
                    if ($receipts.ContainsKey($altKey)) {
                        $matched = $receipts[$altKey]
                        $rec = $matched.filename
                        break
                    }
                }
            }
        }
    }

    $notes = ""
    if ($cat -eq "Unidentified Income") { $notes = "MANUAL REVIEW  not matched to register or DD ledger" }
    if ($cat -eq "Owner Funding") { $notes = "User Reviewed  owner SHL transfer" }

    # Determine programmatic exemption reason
    $receiptExempt = ""
    if ($isCredit) {
        $receiptExempt = "Income - no receipt required"
    } elseif ($exemptCategories -contains $cat) {
        $receiptExempt = "Programmatic exemption: $cat"
    }

    Write-Row $dt $acctLabel $amt $fullDesc $cat $room $tenant $period $regRef $ddRef $rec $zohoId $sourceLabel $notes $receiptExempt
}

# 
# File-level deduplication: Zoho rows with positive zoho_transaction_id
# take priority over raw-bank rows for the same date+amount (since Zoho
# represents the cloud books after Plaid reconciliation).
# 
$global:seenKey = @{}

function ConvertTo-IsoDate($dt) {
    # Normalize a date string to YYYY-MM-DD so raw (M/D/YYYY, TD/RBC) and
    # Zoho/Scotia (YYYY-MM-DD) formats share one key format. Passes ISO dates
    # through unchanged; leaves unrecognized formats as-is.
    $normDt = $dt
    if ($dt -match '^(\d{1,2})/(\d{1,2})/(\d{4})$') {
        $normDt = '{0:D4}-{1:D2}-{2:D2}' -f [int]$Matches[3], [int]$Matches[1], [int]$Matches[2]
    }
    return $normDt
}

function Dedup-Key($dt, $amt, $desc, $src, $acctLabel) {
    # Normalize date to YYYY-MM-DD so raw (M/D/YYYY) and Zoho (YYYY-MM-DD) formats match
    $normDt = ConvertTo-IsoDate $dt
    $rounded = "{0:F2}" -f [math]::Round($amt, 2)
    # Include normalized description to prevent false dedup of different txns same date+amount
    $normDesc = if ($desc) { ($desc -replace '\s+', ' ').Trim().ToLower() } else { '' }
    $key = "$normDt|$rounded|$normDesc|$acctLabel"
    if ($global:seenKey.ContainsKey($key)) {
        $existing = $global:seenKey[$key]
        if ($src -match "Zoho" -and $existing -notmatch "Zoho") {
            $global:seenKey[$key] = $src
            return $false
        }
        return $true
    }
    $global:seenKey[$key] = $src
    return $false
}

# 
# Pipeline integrity check - verify all source directories exist before processing
# 
$fatalMissing = [System.Collections.Generic.List[string]]::new()
if (-not (Test-Path $bankDir)) {
    [void]$fatalMissing.Add("Bank statements directory: $bankDir")
}
if (-not (Test-Path $regPath)) {
    [void]$warnings.Add("Rent register not found: $regPath - rent matching disabled")
}
if (-not (Test-Path $ddPath)) {
    [void]$warnings.Add("Damage deposit ledger not found: $ddPath - DD matching disabled")
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

# 
# Verification gate: source CSVs must exist with non-zero row counts
# 
foreach ($acct in $accounts) {
    $acctDir = "$bankDir\$($acct.folder)"
    $rawPath = "$acctDir\$($acct.raw)"
    if (Test-Path $rawPath) {
        $rawContent = Get-Content $rawPath -ErrorAction SilentlyContinue
        $dataRows = @($rawContent | Where-Object { $_ -notmatch '^#' -and $_ -match '\d' -and $_ -notmatch '^(Date|Transaction Date)"' })
        if ($dataRows.Count -eq 0) {
            Write-Warning "Source CSV has no data rows: $rawPath — $($acct.label) will have no raw data"
            [void]$warnings.Add("Empty raw CSV: $rawPath — $($acct.label) will have no raw data")
        } else {
            Write-Verbose "  $($acct.label) raw CSV: $($dataRows.Count) data rows"
        }
    }
    $zohoPath = "$acctDir\$($acct.zoho)"
    if (Test-Path $zohoPath) {
        $zohoContent = Get-Content $zohoPath -ErrorAction SilentlyContinue
        $zohoDataRows = @($zohoContent | Where-Object { $_ -notmatch '^#' -and $_ -match '\d{4}-\d{2}-\d{2}' })
        if ($zohoDataRows.Count -eq 0) {
            Write-Warning "Zoho CSV has no data rows: $zohoPath — $($acct.label) will have no Zoho supplement"
            [void]$warnings.Add("Empty Zoho CSV: $zohoPath — $($acct.label) will have no Zoho supplement")
        }
    }
}

# 
# Read upstream pipeline warnings from statement directories
# 
$pipelineWarningsFiles = Get-ChildItem -Path $bankDir -Recurse -Filter "*.pipeline-warnings.json" -ErrorAction SilentlyContinue
$upstreamWarnings = @()
foreach ($wf in $pipelineWarningsFiles) {
    try {
        $content = Get-Content $wf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $upstreamWarnings += $content
        Write-Verbose "  Read upstream warnings: $($wf.FullName) ($($content.Count) entries)"
    } catch {
        [void]$warnings.Add("Failed to parse pipeline warnings: $($wf.FullName): $_")
    }
}
if ($upstreamWarnings.Count -gt 0) {
    Write-Host "[VERIFY] Upstream pipeline warnings: $($upstreamWarnings.Count)" -ForegroundColor Yellow
    foreach ($uw in $upstreamWarnings) {
        Write-Host "  [$($uw.severity)] $($uw.message)" -ForegroundColor $(if ($uw.severity -eq 'error') {'Red'} else {'Yellow'})
    }
}

# 
# Parse all source files
# 
foreach ($acct in $accounts) {
    $acctDir = "$bankDir\$($acct.folder)"
    $rawPath = "$acctDir\$($acct.raw)"
    $zohoPath = "$acctDir\$($acct.zoho)"
    $label = $acct.label

    # Parse raw bank CSV FIRST - it has the complete transaction list with correct signs.
    # Cross-source dedup registers Raw entries. Zoho entries with matching date|amount|account
    # are then skipped, preventing duplicates from incomplete/merged Zoho data.
    if (Test-Path $rawPath) {
        $sourceLabel = "Raw:$label"
        if ($label -match "SCOTIA") { Parse-RawScotia $rawPath $label }
        elseif ($label -match "TD-MLM") { Parse-RawTD $rawPath $label }
        elseif ($label -match "RBC-FRA") { Parse-RawRBC $rawPath $label }
    } else {
        [void]$warnings.Add("Raw bank CSV not found: $rawPath")
    }

    # Parse Zoho as SUPPLEMENT - only entries past the raw CSV cutoff AND with
    # a different date|amount|account from Raw get through. This gates out
    # phantom Zoho entries that don't correspond to actual bank transactions.
    if (Test-Path $zohoPath) {
        $global:zohoCutoffDate = $acct.rawCutoff
        $sourceLabel = "Zoho:$label"
        $zCount = Parse-Zoho $zohoPath $label
        if ($zCount -eq 0) {
            [void]$warnings.Add("Zoho export has 0 transactions: $zohoPath  run Bookkeeper MCP route (POST /zoho/transactions/export) to refresh")
        }
    }
}

# Verification gate: ensure source CSVs produced data before cross-referencing
if ($rows.Count -lt 1) {
    Write-Warning "No transaction rows parsed from any source CSV - TAS would be empty. Aborting cross-reference."
    return
}
Write-Host "[VERIFY] Parsed $($rows.Count) total transaction rows from source CSVs"
Write-Verbose "[VERIFY] Source accounts checked: $(($accounts | Where-Object { Test-Path "$bankDir\$($_.folder)\$($_.raw)" }).Count) with raw CSVs"

# 
# Post-processing: cross-account Transfer Out matching
# Scans all rows classified as "Transfer Out" and tries to match
# the amount against known credits in cross-reference accounts.
# 
$updatedTransferOuts = 0
for ($i = 0; $i -lt $rows.Count; $i++) {
    $r = $rows[$i]
    if ($r.category -ne "Transfer Out") { continue }
    $result = Resolve-TransferOutMatch $r.date $r.amount
    if ($result.matched) {
        $r.category = "Credit Card Payment"
        $r.notes = if ($r.notes) { "$($r.notes); cross-ref $($result.target)" } else { "cross-ref $($result.target)" }
        $updatedTransferOuts++
    }
}
if ($updatedTransferOuts -gt 0) {
    [void]$warnings.Add("Cross-account matched $updatedTransferOuts Transfer Out entries as Credit Card Payments")
}

# 
# Backfill descriptions from raw bank CSVs for Zoho rows that lost them
# Zoho's banktransactions API drops descriptions for processed/categorized transactions.
# 
$rawLookup = @{}
foreach ($acct in $accounts) {
    $rawPath = "$bankDir\$($acct.folder)\$($acct.raw)"
    if (-not (Test-Path $rawPath)) { continue }
    $acctLabel = $acct.label
    $rawData = if ($acctLabel -match "SCOTIA") {
        # Scotia raw CSV: custom format, parse with helper
        $lines = Get-Content $rawPath
        $result = @()
        for ($i = 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i].Trim()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^("",)+""$') { continue }
            if ($line -notmatch '^"","(\d{4}-\d{2}-\d{2})"') { continue }
            $f = $line -split '","' | ForEach-Object { $_.Trim('"') }
            if ($f.Count -lt 7) { continue }
            $dt = $f[1]; $desc = $f[2]; $sub = $f[3]; $type = $f[4]
            $amt = if ($type -eq "Credit") { [double]$f[5] } else { -[double]($f[5].TrimStart('-')) }
            $result += [PSCustomObject]@{ Transaction_Date = $dt; Description = "$desc $sub".Trim(); CAD_ = $amt }
        }
        $result
    } elseif ($acctLabel -match "TD-MLM") {
        $tdData = Import-Csv $rawPath
        $tdData | Where-Object { $_.Credit -or $_.Debit } | ForEach-Object {
            $dt = $_.Date; $desc = $_.Description
            $amt = 0
            if (-not [string]::IsNullOrWhiteSpace($_.Credit)) { $amt = [double]$_.Credit }
            elseif (-not [string]::IsNullOrWhiteSpace($_.Debit)) { $amt = -[double]$_.Debit }
            [PSCustomObject]@{ Transaction_Date = $dt; Description = $desc; CAD_ = $amt }
        }
    } else {
        # RBC: standard format
        $rbcData = Import-Csv $rawPath
        $rbcData | Where-Object { -not [string]::IsNullOrWhiteSpace($_.'Transaction Date') } | ForEach-Object {
            [PSCustomObject]@{ Transaction_Date = $_."Transaction Date"; Description = "$($_."Description 1") $($_."Description 2")".Trim(); CAD_ = [double]$_."CAD$" }
        }
    }
    foreach ($row in $rawData) {
        $dtStr = $row.Transaction_Date
        if ([string]::IsNullOrWhiteSpace($dtStr)) { continue }
        try { $dt = ([DateTime]::Parse($dtStr)).ToString('yyyy-MM-dd') } catch { $dt = $dtStr }
        $amt = $row.CAD_
        $fullDesc = if ($row.Description) { $row.Description } else { "" }
        $key = "$dt|$("{0:F2}" -f $amt)|$acctLabel"
        $rawLookup[$key] = $fullDesc
    }
}
$backfilledCount = 0
$backfillCandidates = 0
foreach ($r in $rows) {
    $needsBackfill = [string]::IsNullOrWhiteSpace($r.description) -or @('Other Expenses', 'Shareholder Loan') -contains $r.description.Trim()
    if ($needsBackfill) {
        $backfillCandidates++
        $amtKey = "{0:F2}" -f [double]$r.amount
        # Normalize the row-side date to YYYY-MM-DD — rawLookup keys are built
        # from normalized dates, so a raw TD (M/D/YYYY) or RBC (Transaction
        # Date) row would otherwise never match and the backfill would
        # silently no-op.
        $normDate = ConvertTo-IsoDate $r.date
        $key = "$normDate|$amtKey|$($r.bank_account)"
        if ($rawLookup.ContainsKey($key)) {
            $r.description = $rawLookup[$key]
            $backfilledCount++
        }
    }
}
if ($backfilledCount -gt 0) {
    [void]$warnings.Add("Backfilled $backfilledCount descriptions from raw bank CSVs")
} elseif ($backfillCandidates -gt 0 -and $rawLookup.Count -gt 0) {
    [void]$warnings.Add("WARN: $backfillCandidates rows needed description backfill but none matched ($($rawLookup.Count) raw rows available) - possible date-format drift")
}

# 
# Preserve user-set receipt_exempt values from old TAS
# 
$oldTasPath = "$RootDir\TAS-$FiscalYear.csv"
if (Test-Path $oldTasPath) {
    try {
        $oldRows = Import-Csv $oldTasPath
        $oldExempt = @{}
        foreach ($or in $oldRows) {
            $exemptVal = if ($or.receipt_exempt) { $or.receipt_exempt.Trim() } else { "" }
            if (-not [string]::IsNullOrWhiteSpace($exemptVal)) {
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
# Sort: by bank_account, then date
# 
$rows = $rows | Sort-Object bank_account, date

# 
# Build source file manifest
# 
$manifestLines = [System.Collections.ArrayList]@()
[void]$manifestLines.Add("# Transaction Annual Statement  Room Rentals $FiscalYear")
[void]$manifestLines.Add("# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void]$manifestLines.Add("# Generator: Skills/Bookkeeping/Scripts/Build-TAS.ps1")
[void]$manifestLines.Add("# Total transactions: $($rows.Count)")
[void]$manifestLines.Add("#")
[void]$manifestLines.Add("# Source files:")
foreach ($acct in $accounts) {
    $acctDir = "$bankDir\$($acct.folder)"
    foreach ($kind in @("raw", "zoho")) {
        $fn = $acct.$kind
        $fp = "$acctDir\$fn"
        if (Test-Path $fp) {
            $fi = Get-Item $fp
            $hash = (Get-FileHash $fp -Algorithm SHA256).Hash.Substring(0, 16)
            [void]$manifestLines.Add("#   $fn  |  $($fi.Length) bytes  |  $($fi.LastWriteTime.ToString('yyyy-MM-dd'))  |  $hash...")
        }
    }
}
[void]$manifestLines.Add("#")
[void]$manifestLines.Add("# Reference files:")
foreach ($rf in @($regPath, $ddPath, $manPath)) {
    if (Test-Path $rf) {
        $fi = Get-Item $rf
        [void]$manifestLines.Add("#   $(Split-Path $rf -Leaf)  |  $($fi.Length) bytes  |  $($fi.LastWriteTime.ToString('yyyy-MM-dd'))")
    }
}
if ($warnings.Count -gt 0) {
    [void]$manifestLines.Add("#")
    [void]$manifestLines.Add("# Warnings:")
    foreach ($w in $warnings) { [void]$manifestLines.Add("#   WARN: $w") }
}

# 
# Write combined pipeline warnings
# 
$allWarnings = @()
foreach ($uw in $upstreamWarnings) { $allWarnings += $uw }
foreach ($w in $warnings) {
    $allWarnings += @{
        stage = 'Build-TAS'
        file = $tasPath
        severity = 'warning'
        message = $w
    }
}
$warningsPath = "$RootDir\.pipeline-warnings.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($warningsPath, ($allWarnings | ConvertTo-Json -Depth 3), $utf8NoBom)
if ($allWarnings.Count -gt 0) {
    Write-Host "[VERIFY] Combined pipeline warnings: $($allWarnings.Count) entries → $warningsPath" -ForegroundColor Yellow
}

# 
# Write output
# 
if ($WhatIf) {
    Write-Host "`n=== TAS-$FiscalYear GENERATION (WHATIF) ===" -ForegroundColor Cyan
    Write-Host "Fiscal Year: $FiscalYear" -ForegroundColor Cyan
    Write-Host "Expected source files:" -ForegroundColor Cyan
    foreach ($acct in $accounts) {
        $acctDir = "$bankDir\$($acct.folder)"
        $rawPath = "$acctDir\$($acct.raw)"
        $zohoPath = "$acctDir\$($acct.zoho)"
        $rawExists = if (Test-Path $rawPath) { "found" } else { "MISSING" }
        $zohoExists = if (Test-Path $zohoPath) { "found" } else { "MISSING" }
        Write-Host "  $($acct.slug): raw=[$rawExists] $($acct.raw), zoho=[$zohoExists] $($acct.zoho)" -ForegroundColor $(if ($rawExists -eq "MISSING" -or $zohoExists -eq "MISSING") { "Yellow" } else { "Gray" })
    }
    Write-Host "Transactions: $($rows.Count)" -ForegroundColor Yellow
    Write-Host "Source files: $($sourcesUsed.Count)" -ForegroundColor Yellow
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:" -ForegroundColor Red
        foreach ($w in $warnings) { Write-Host "  $w" -ForegroundColor Red }
    }
    # Show a sample of unmatched items
    $unmatched = $rows | Where-Object { $_.category -eq "Unidentified Income" }
    if ($unmatched) {
        Write-Host "Unidentified Income rows: $($unmatched.Count)" -ForegroundColor Yellow
        $unmatched | Select-Object date, bank_account, amount, description | Format-Table -AutoSize
    }
    $rows | Select-Object date, bank_account, amount, category, source | Format-Table -AutoSize
} else {
    $header = $manifestLines -join "`n"
    $csvContent = $rows | ConvertTo-Csv -NoTypeInformation
    # Write manifest header + CSV body (BOM-free UTF-8 on both PS 5.1 and PS 7)
    [System.IO.File]::WriteAllText($tasPath, $header + "`n" + ($csvContent -join "`n"), $utf8NoBom)
    Write-Host "TAS written: $tasPath ($($rows.Count) rows)" -ForegroundColor Green
    if ($warnings.Count -gt 0) {
        Write-Host "Warnings:" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "  $w" -ForegroundColor Yellow }
    }
}
