<#
.SYNOPSIS
    PRP Step 1: Verify sidecar CSVs against TAS-2026.csv.
.DESCRIPTION
    Wraps reconcile-sidecars-vs-csv.py invocation, parses JSON output,
    returns verdict and unmatched transactions array. Confirms every
    sidecar transaction matches a TAS row by (date, amount, direction).
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting" or "room-rentals").
.PARAMETER AccountName
    Account slug for sidecar directory lookup.
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
    Invoke-PrpStep1-SidecarVerify.ps1 -OrgName "intersite-consulting" -AccountName "RBC-INTERSITE"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter(Mandatory)]
    [string]$AccountName,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId,

    [Parameter()]
    [string]$pythonPath = "python",

    [Parameter()]
    [string]$Platform = 'Host'
)

$ErrorActionPreference = "Stop"
$stepNumber = 1
$stepName = "Sidecar Verification"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir)))
$pyScript = Join-Path $scriptDir "reconcile-sidecars-vs-csv.py"

# Load PRP config for this org/account
. (Join-Path $scriptDir "Get-PrpConfig.ps1")
$prpCfg = Get-PrpConfig -OrgName $OrgName
$acctCfg = Get-PrpConfig -OrgName $OrgName -AccountName $AccountName

$orgBooksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$OrgName"

# Resolve sidecar dir - use config bank_statement_folder if available
$stmtFolder = if ($acctCfg.bank_statement_folder) { $acctCfg.bank_statement_folder } else { $AccountName }
$bsRoot = $prpCfg.org.bank_statements_root
$sidecarDir = "$orgBooksRoot\$bsRoot\$stmtFolder"
if (-not (Test-Path -LiteralPath $sidecarDir)) {
    $sidecarDir = "$orgBooksRoot\2026 Filing\2026 Bank Statements\$stmtFolder"
}
if (-not (Test-Path -LiteralPath $sidecarDir)) {
    $sidecarDir = "$orgBooksRoot\2026 Bank Statements\$stmtFolder"
}
if (-not (Test-Path -LiteralPath $sidecarDir)) {
    $bankCandidates = Get-ChildItem "$orgBooksRoot\*Bank Statements*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($bankCandidates) { $sidecarDir = Join-Path $bankCandidates[0].FullName $stmtFolder }
}

# Resolve TAS path - use config tas_file if available
$tasFileName = if ($prpCfg.org.tas_file) { $prpCfg.org.tas_file } else { "TAS-2026.csv" }
$tasPath = Join-Path $orgBooksRoot $tasFileName
if (-not (Test-Path -LiteralPath $tasPath)) {
    $tasTries = Get-ChildItem (Join-Path $orgBooksRoot "TAS-*.csv") -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if ($tasTries) { $tasPath = $tasTries[0].FullName }
}

$reconPeriodsFileName = if ($prpCfg.org.reconciliation_periods_file) { $prpCfg.org.reconciliation_periods_file } else { "reconciliation-periods.md" }
$reconPeriodsFile = "$orgBooksRoot\$reconPeriodsFileName"

if (-not (Test-Path -LiteralPath $pyScript)) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "reconcile-sidecars-vs-csv.py not found at $pyScript"
        NextSteps  = @("Verify Bookkeeping scripts are installed")
        Verdict    = "error"
        UnmatchedTxns = @()
    }
}

# ---- Recovery: auto-generate sidecar CSVs from PDF bank statements ----
$sidecarCsvCount = if (Test-Path -LiteralPath $sidecarDir) {
    @(Get-ChildItem "$sidecarDir\*.csv" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Zoho|Fiscal|zoho|dry-run' }).Count
} else { 0 }

if ($sidecarCsvCount -eq 0) {
    $pdfPyScript = Join-Path (Split-Path -Parent $scriptDir) "..\pdf\convert-pdf-statement-to-sidecar.py"
    if (Test-Path $pdfPyScript) {
        $pdfToConvert = Get-ChildItem "$sidecarDir\*.pdf" -ErrorAction SilentlyContinue
        if (-not $pdfToConvert) {
            $altPaths = @(
                "$orgBooksRoot\$bsRoot\$stmtFolder",
                "$orgBooksRoot\2026 Filing\2026 Bank Statements\$stmtFolder",
                "$orgBooksRoot\2026 Bank Statements\$stmtFolder"
            ) | Where-Object { Test-Path $_ }
            foreach ($ap in $altPaths) {
                $pdfToConvert = Get-ChildItem "$ap\*.pdf" -ErrorAction SilentlyContinue
                if ($pdfToConvert) { $sidecarDir = $ap; break }
            }
        }
        if ($pdfToConvert) {
            $null = New-Item -ItemType Directory -Path $sidecarDir -Force
            foreach ($pdf in $pdfToConvert) {
                Write-Information "[PRP STEP 1] Converting PDF: $($pdf.Name)" -Tags PRP
                & $pythonPath $pdfPyScript "$($pdf.FullName)" --output "$sidecarDir" 2>&1 | Out-Null
                Write-Information "[SIDECAR GEN] Generated sidecar from $($pdf.Name)" -Tags PRP
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $sidecarDir)) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "Sidecar directory not found: $sidecarDir"
        NextSteps  = @("Run statement PDF conversion first", "Verify org and account names")
        Verdict    = "error"
        UnmatchedTxns = @()
    }
}

if (-not (Test-Path -LiteralPath $tasPath)) {
    return [PSCustomObject]@{
        StepNumber = $stepNumber
        Passed     = $false
        Details    = "TAS file not found: $tasPath"
        NextSteps  = @("Run Build-TAS.ps1 or Build-IntersiteTAS.ps1 first")
        Verdict    = "error"
        UnmatchedTxns = @()
    }
}

# ---- Date helper: parse with multiple formats using try/catch (avoids TryParseExact overload issues) ----
function Parse-FlexibleDate {
    param([string]$DateStr, [string[]]$Formats)
    $clean = $DateStr.Trim() -replace ',', ''
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
    foreach ($fmt in $Formats) {
        try { return [datetime]::ParseExact($clean, $fmt, [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $null
}

# ---- Helper: parse reconciliation-periods.md for this account ----
function Get-SidecarPeriods {
    param([string]$MdPath, [string]$AccountName)
    if (-not (Test-Path -LiteralPath $MdPath)) {
        Write-Warning "[PRP STEP 1] reconciliation-periods.md not found at $MdPath"
        return @()
    }
    $periods = @()
    $lines = Get-Content -LiteralPath $MdPath
    $inTargetSection = $false
    # Flexible section matching: use config section_header_prefix, or fall back to account name prefix
    $acctPrefix = if ($acctCfg.section_header_prefix) { $acctCfg.section_header_prefix } else { ($AccountName -replace '[-_\s].*', '') }
    $sectionHeaderPattern = "^##\s+$([Regex]::Escape($acctPrefix))"
    foreach ($line in $lines) {
        if ($line -match $sectionHeaderPattern) {
            $inTargetSection = $true
            continue
        }
        if ($inTargetSection) {
            if ($line -match '^\|(.+)\|(.+)\|$') {
                $periodStr = $matches[1].Trim()
                $balanceStr = $matches[2].Trim()
                if ($periodStr -match '–\s*([A-Za-z]+\s*\d+,?\s*\d{4})') {
                    $endDateStr = $matches[1]
                    $endFmts = @("MMM dd yyyy", "MMMM dd yyyy", "MMM d yyyy", "MMMM d yyyy")
                    $endDate = Parse-FlexibleDate -DateStr $endDateStr -Formats $endFmts
                    if (-not $endDate) { continue }
                    $balance = [decimal]($balanceStr -replace '[$,]', '')
                    $periodStartStr = ($periodStr -split '–')[0].Trim()
                    $hasYearInStart = $periodStartStr -match '\d{4}'
                    $startFmts = @("MMM dd yyyy", "MMMM dd yyyy", "MMM d yyyy", "MMMM d yyyy", "MMM dd", "MMMM dd", "MMM d", "MMMM d")
                    $startDate = Parse-FlexibleDate -DateStr $periodStartStr -Formats $startFmts
                    # If start date was parsed without an explicit year in the string, force year from end date
                    if ($startDate -and -not $hasYearInStart -and $endDate) {
                        $startDate = [datetime]::new($endDate.Year, $startDate.Month, $startDate.Day)
                    }
                    # If start date still null, fall back to 1 month before end
                    if (-not $startDate) { $startDate = $endDate.AddMonths(-1) }
                    $periods += [PSCustomObject]@{
                        start          = $startDate
                        end            = $endDate
                        opening_balance = [decimal]0
                        closing_balance = $balance
                        label          = "$($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"
                    }
                }
            } elseif ($line -match '^##\s') {
                break
            }
        }
    }
    return $periods
}

# ---- Helper: read sidecar CSVs for this account ----
function Get-SidecarTransactions {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) {
        Write-Warning "[PRP STEP 1] Sidecar directory not found at $Dir"
        return @()
    }
    $txns = @()
    $skippedEmpty = 0
    $csvFiles = Get-ChildItem -LiteralPath $Dir -Filter "*.csv" | Where-Object { $_.Name -notmatch 'Zoho' -and $_.Name -notmatch 'Fiscal' -and $_.Name -notmatch 'dry-run' -and $_.Name -notmatch 'zoho' }
    foreach ($csv in $csvFiles) {
        try {
            $rows = Import-Csv -LiteralPath $csv.FullName
            foreach ($row in $rows) {
                if ([string]::IsNullOrWhiteSpace($row.date)) { $skippedEmpty++; continue }
                if ([string]::IsNullOrWhiteSpace($row.amount)) { $skippedEmpty++; continue }
                $parsedDate = Parse-FlexibleDate -DateStr $row.date -Formats @("yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "yyyy-M-d")
                if (-not $parsedDate) {
                    Write-Warning "[PRP STEP 1] Cannot parse date '$($row.date)' in $($csv.Name) — skipping row"
                    continue
                }
                $amount = [decimal]0
                $amtStr = ($row.amount -replace '[^0-9.\-]', '').Trim()
                if (-not [decimal]::TryParse($amtStr, [ref]$amount)) {
                    Write-Warning "[PRP STEP 1] Cannot parse amount '$($row.amount)' in $($csv.Name) — skipping row"
                    continue
                }
                $txns += [PSCustomObject]@{
                    date        = $parsedDate
                    payee       = $row.payee
                    description = $row.description
                    type        = $row.debit_or_credit
                    amount      = $amount
                }
            }
        } catch {
            Write-Warning "[PRP STEP 1] Failed to read $($csv.Name): $_"
        }
    }
    if ($skippedEmpty -gt 0) {
        Write-Information "[PRP STEP 1] Skipped $skippedEmpty empty/malformed rows" -Tags PRP
    }
    return $txns
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 1] WhatIf: would run python $pyScript --sidecar-dir $sidecarDir --tas $tasPath --json" -Tags PRP
    Write-Information "[PRP STEP 1] WhatIf: would parse periods from $reconPeriodsFile and sidecar CSVs from $sidecarDir" -Tags PRP
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $true
        Details        = "WhatIf: sidecar verification skipped"
        NextSteps      = @("Run without -WhatIf to execute verification")
        Verdict        = "whatif"
        UnmatchedTxns  = @()
        SidecarPeriods = @()
        SidecarData    = @()
    }
}

Write-Information "[PRP STEP 1] Running sidecar verification for $AccountName" -Tags PRP

# Parse sidecar periods and transactions for downstream steps
$sidecarPeriods = Get-SidecarPeriods -MdPath $reconPeriodsFile -AccountName $AccountName
$sidecarData = Get-SidecarTransactions -Dir $sidecarDir

Write-Information "[PRP STEP 1] Parsed $($sidecarPeriods.Count) periods, $($sidecarData.Count) statement transactions" -Tags PRP

# ---- Sidecar vs TAS comparison ----
$unmatchedInTas = @()
$sourceWarning = $false
if ($sidecarData.Count -gt 0 -and (Test-Path $tasPath)) {
    Write-Information "[PRP STEP 1] Running sidecar vs TAS comparison..." -Tags PRP
    $tasLines = Get-Content $tasPath
    $tasDataStart = 0
    for ($ti = 0; $ti -lt $tasLines.Count; $ti++) { if ($tasLines[$ti] -notmatch '^#') { $tasDataStart = $ti; break } }
    $tasDataLines = $tasLines[($tasDataStart + 1)..($tasLines.Count - 1)]
    $tasAll = @()
    foreach ($tl in $tasDataLines) {
        if ([string]::IsNullOrWhiteSpace($tl)) { continue }
        $tc = $tl -split ','
        if ($tc.Count -lt 5) { continue }
        $tasAll += [PSCustomObject]@{
            date    = $tc[0].Trim('"')
            account = $tc[1].Trim('"')
            amount  = [double]($tc[2].Trim('"'))
            desc    = $tc[3].Trim('"')
            source  = $tc[7].Trim('"')
        }
    }

    # Find each sidecar transaction in TAS by (date, amount, direction)
    foreach ($stxn in $sidecarData) {
        $scDate = if ($stxn.date -is [datetime]) { $stxn.date.ToString('yyyy-MM-dd') } else { $stxn.date }
        $scAmt = [math]::Abs($stxn.amount)
        $scDir = $stxn.type
        $match = $tasAll | Where-Object {
            $_.date -eq $scDate -and
            [math]::Abs([math]::Abs($_.amount) - $scAmt) -lt 0.01 -and
            (($_.amount -gt 0 -and $scDir -eq 'credit') -or ($_.amount -lt 0 -and $scDir -eq 'debit') -or ($_.amount -eq 0))
        }
        if (-not $match) {
            $unmatchedInTas += $stxn
        }
    }

    if ($unmatchedInTas.Count -gt 0) {
        Write-Warning "[PRP STEP 1] $($unmatchedInTas.Count) sidecar transaction(s) not found in TAS:"
        foreach ($u in $unmatchedInTas) {
            $uDate = if ($u.date -is [datetime]) { $u.date.ToString('yyyy-MM-dd') } else { $u.date }
            Write-Warning "  $uDate  $($u.type)  $($u.amount)  $($u.payee)"
        }
        $sourceWarning = $true
    } else {
        Write-Information "[PRP STEP 1] All sidecar transactions match TAS" -Tags PRP
    }
} else {
    if ($sidecarData.Count -eq 0) { Write-Warning "[PRP STEP 1] No sidecar data to compare against TAS" }
    if (-not (Test-Path $tasPath)) { Write-Warning "[PRP STEP 1] TAS not found: $tasPath — skipping comparison" }
}

$periodCount = $sidecarPeriods.Count
$passed = $periodCount -gt 0 -and (-not $sourceWarning)
$detail = "$periodCount period(s) parsed from reconciliation-periods.md, $($sidecarData.Count) statement transaction(s)"
if ($unmatchedInTas.Count -gt 0) {
    $detail += ", $($unmatchedInTas.Count) sidecar transaction(s) not in TAS (⚠)"
}
if (-not $passed) {
    $failReasons = @()
    if ($periodCount -eq 0) { $failReasons += "No periods found" }
    if ($sourceWarning) { $failReasons += "$($unmatchedInTas.Count) transactions missing from TAS" }
    Write-Warning "[PRP STEP 1] FAILED — $($failReasons -join '; ')"
} else {
    Write-Information "[PRP STEP 1] PASSED — $detail" -Tags PRP
}

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed

return [PSCustomObject]@{
    StepNumber     = $stepNumber
    Passed         = $passed
    Details        = $detail
    Verdict        = $(if ($passed) { "pass" } else { "no_periods" })
    UnmatchedTxns  = $unmatchedInTas
    BoundaryItems  = $false
    SidecarPeriods = $sidecarPeriods
    SidecarData    = $sidecarData
    TasPath        = $tasPath
    NextSteps      = @(
        $(if ($passed) { "Proceed to Step 2: Zoho Transaction Match" } else { "Check reconciliation-periods.md has a section for this account name" })
    )
}
