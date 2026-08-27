<#
.SYNOPSIS
    DEPRECATED — Use Invoke-PrpAcctPipeline.ps1 instead.
.DESCRIPTION
    This standalone check has been superseded by the PRP pipeline
    (Invoke-PrpAcctPipeline.ps1), which is idempotent, produces a timestamped
    per-org report with data freshness, and runs all validation steps
    including TAS balance forward, sidecar comparison, and Zoho completeness.
    
    Run the PRP instead:
      .\Invoke-PrpAcctPipeline.ps1 -AccountName "RBC-FRA" -OrgName "room-rentals" ...
    
    This script is kept for reference only and will be removed in a future update.
#>

param(
    [string]$Organization = "intersite-consulting",
    [string]$Account = "",
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$Organization"
$tasPath = "$booksRoot\TAS-2026.csv"
$reconPeriodsPath = "$booksRoot\reconciliation-periods.md"

if (-not (Test-Path $tasPath)) { Write-Error "TAS not found: $tasPath"; exit 1 }
if (-not (Test-Path $reconPeriodsPath)) { Write-Error "reconciliation-periods.md not found: $reconPeriodsPath"; exit 1 }

$bankDir = if ($Organization -eq "room-rentals") { "$booksRoot\2026 Bank Statements" } else { "$booksRoot\2026 Filing\2026 Bank Statements" }

function Parse-FlexibleDate {
    param([string]$DateStr, [string[]]$Formats)
    $clean = $DateStr.Trim() -replace ',', ''
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
    foreach ($fmt in $Formats) {
        try { return [datetime]::ParseExact($clean, $fmt, [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $null
}

# --- Parse reconciliation-periods.md ---
function Get-AccountPeriods {
    param([string]$MdPath, [string]$AccountName)
    if (-not (Test-Path $MdPath)) { return @() }
    $periods = @()
    $lines = Get-Content $MdPath
    $inSection = $false
    $sectionHeaderPattern = "^##\s+$([Regex]::Escape($AccountName))"
    foreach ($line in $lines) {
        if ($line -match $sectionHeaderPattern) { $inSection = $true; continue }
        if ($inSection) {
            if ($line -match '^\|(.+)\|(.+)\|$') {
                $periodStr = $matches[1].Trim()
                $balanceStr = $matches[2].Trim()
                if ($periodStr -match '–\s*([A-Za-z]+\s*\d+,?\s*\d{4})') {
                    $endDateStr = $matches[1]
                    $endDate = Parse-FlexibleDate -DateStr $endDateStr -Formats @("MMM dd yyyy","MMMM dd yyyy","MMM d yyyy","MMMM d yyyy")
                    if (-not $endDate) { continue }
                    $balance = [decimal]($balanceStr -replace '[$,]', '')
                    $periodStartStr = ($periodStr -split '–')[0].Trim()
                    $hasYearInStart = $periodStartStr -match '\d{4}'
                    $startDate = Parse-FlexibleDate -DateStr $periodStartStr -Formats @("MMM dd yyyy","MMMM dd yyyy","MMM d yyyy","MMMM d yyyy","MMM dd","MMMM dd","MMM d","MMMM d")
                    if ($startDate -and -not $hasYearInStart -and $endDate) {
                        $startDate = [datetime]::new($endDate.Year, $startDate.Month, $startDate.Day)
                    }
                    if (-not $startDate) { $startDate = $endDate.AddMonths(-1) }
                    $periods += [PSCustomObject]@{
                        start = $startDate; end = $endDate
                        closing_balance = $balance
                        label = "$($startDate.ToString('yyyy-MM-dd')) to $($endDate.ToString('yyyy-MM-dd'))"
                    }
                }
            } elseif ($line -match '^##\s') { break }
        }
    }
    return $periods
}

# --- Parse TAS ---
$lines = Get-Content $tasPath
$dataStart = 0
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -notmatch '^#') { $dataStart = $i; break } }
$dataLines = $lines[($dataStart + 1)..($lines.Count - 1)]
$allTxns = @()
foreach ($line in $dataLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $cols = $line -split ','
    $allTxns += [PSCustomObject]@{
        date = $cols[0].Trim('"')
        account = $cols[1].Trim('"')
        amount = [double]$cols[2].Trim('"')
        desc = $cols[3].Trim('"')
    }
}

# --- Read sidecar CSVs ---
function Get-SidecarTxns($AccountName, $PeriodStart, $PeriodEnd) {
    $folder = $AccountName
    $stmtDir = "$bankDir\$folder"
    if (-not (Test-Path $stmtDir)) { return $null }
    $stmtFile = Get-ChildItem "$stmtDir\*$($PeriodEnd.ToString('yyyy-MM-dd')).csv" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'Zoho' -and $_.Name -notmatch 'zoho' -and $_.Name -notmatch 'dry-run' } |
        Select-Object -First 1
    if (-not $stmtFile) { return $null }
    $rows = Get-Content $stmtFile.FullName | Where-Object { $_ -notmatch '^#' -and $_ -match '\d{4}-\d{2}-\d{2}' }
    $txns = @()
    foreach ($l in $rows) {
        $c = $l -split ','
        if ($c.Count -lt 5) { continue }
        try {
            $amt = [double]$c[4].Trim('"')
            $dc = $c[3].Trim('"')
            $signed = if ($dc -eq 'debit' -or $dc -eq 'Debit') { -$amt } else { $amt }
            $txns += [PSCustomObject]@{
                date = $c[0].Trim('"')
                payee = $c[1].Trim('"')
                amount = $signed
                amountAbs = $amt
                dc = $dc
            }
        } catch {}
    }
    $txns
}

# --- Account definitions from config ---
$accountDefs = switch ($Organization) {
    "intersite-consulting" {
        @(
            @{ label = "RBC-INTERSITE"; folder = "RBC-INTERSITE"; isCreditCard = $false }
            @{ label = "MC-6258"; folder = "MC 6241 (6258)"; isCreditCard = $true }
        )
    }
    "room-rentals" {
        @(
            @{ label = "RBC-FRA"; folder = "RBC-FRA-5172549"; isCreditCard = $false }
            @{ label = "TD-MLM"; folder = "TD-MLM-6467010"; isCreditCard = $false }
            @{ label = "SCOTIA-TMH"; folder = "SCOTIA-TMH 406000697486"; isCreditCard = $false }
            @{ label = "RBC-VISA"; folder = "RBC-FRA-6679"; isCreditCard = $true }
        )
    }
}

function Write-Status($text, $color) { Write-Host $text -ForegroundColor $color }
$allOk = $true
$orgResults = @()

foreach ($acct in $accountDefs) {
    if ($Account -and $acct.label -ne $Account) { continue }
    $periods = Get-AccountPeriods -MdPath $reconPeriodsPath -AccountName $acct.label
    if ($periods.Count -eq 0) { Write-Status "  No periods found for $($acct.label)" "Yellow"; continue }

    $txns = $allTxns | Where-Object { $_.account -eq $acct.label }

    Write-Status "`n══════════════════════════════════════════" "Cyan"
    Write-Status "  $($acct.label)" "Cyan"
    Write-Status "══════════════════════════════════════════" "Cyan"

    $tableRows = @()
    $prevEnd = $null
    $opening = $null

    for ($i = 0; $i -lt $periods.Count; $i++) {
        $p = $periods[$i]
        $periodTxns = if ($i -eq 0) {
            $txns | Where-Object { $_.date -ge $p.start.ToString('yyyy-MM-dd') -and $_.date -le $p.end.ToString('yyyy-MM-dd') }
        } else {
            $txns | Where-Object { $_.date -gt $prevEnd.ToString('yyyy-MM-dd') -and $_.date -le $p.end.ToString('yyyy-MM-dd') }
        }
        $netFlow = [math]::Round(($periodTxns | Measure-Object amount -Sum).Sum, 2)
        if (-not $netFlow) { $netFlow = 0 }
        if ($i -eq 0) {
            if ($acct.isCreditCard) {
                $opening = [math]::Round($p.closing_balance + $netFlow, 2)
            } else {
                $opening = [math]::Round($p.closing_balance - $netFlow, 2)
            }
        }
        $tasClosing = if ($acct.isCreditCard) {
            [math]::Round($opening - $netFlow, 2)
        } else {
            [math]::Round($opening + $netFlow, 2)
        }
        $diff = [math]::Round($tasClosing - $p.closing_balance, 2)
        $credits = [math]::Round(($periodTxns | Where-Object { $_.amount -gt 0 } | Measure-Object amount -Sum).Sum, 2)
        $debits = [math]::Round(($periodTxns | Where-Object { $_.amount -lt 0 } | Measure-Object amount -Sum).Sum, 2)
        if (-not $credits) { $credits = 0 }
        if (-not $debits) { $debits = 0 }

        $abs = [math]::Abs($diff)
        $status = if ($abs -le 0.02) { '✅' } elseif ($abs -le 50) { '⚠' } else { '❌' }
        if ($abs -gt 0.02) { $allOk = $false }

        $tableRows += [PSCustomObject]@{
            PeriodEnd = $p.end.ToString('yyyy-MM-dd')
            Opening = $opening
            Credits = $credits
            Debits = $debits
            NetFlow = $netFlow
            TASClosing = $tasClosing
            StmtClosing = $p.closing_balance
            Diff = $diff
            Status = $status
        }

        # --- Sidecar transaction comparison ---
        $sidecarTxns = Get-SidecarTxns -AccountName $acct.folder -PeriodStart $p.start -PeriodEnd $p.end
        if ($sidecarTxns) {
            $scNet = [math]::Round(($sidecarTxns | Measure-Object amount -Sum).Sum, 2)
            $scDiff = [math]::Round([math]::Abs($scNet - $netFlow), 2)
            if ($scDiff -gt 0.02) {
                Write-Status "  ⚠ Period $($p.end.ToString('yyyy-MM-dd')): TAS net=$netFlow vs sidecar net=$scNet (diff=$scDiff)" "Yellow"
                if ($Detailed) {
                    # Find missing/extra in TAS vs sidecar
                    foreach ($st in $sidecarTxns) {
                        $match = $periodTxns | Where-Object { [math]::Abs($_.amount - $st.amount) -lt 0.01 -and $_.date -eq $st.date }
                        if (-not $match) {
                            Write-Status "    Sidecar only: $($st.date)  $($st.amount)  $($st.payee)" "Red"
                        }
                    }
                    foreach ($tt in $periodTxns) {
                        $match = $sidecarTxns | Where-Object { [math]::Abs($_.amount - $tt.amount) -lt 0.01 -and $_.date -eq $tt.date }
                        if (-not $match) {
                            Write-Status "    TAS only: $($tt.date)  $($tt.amount)  $($tt.desc)" "Yellow"
                        }
                    }
                }
            }
        } elseif ($Detailed) {
            Write-Status "  No sidecar CSV found for period ending $($p.end.ToString('yyyy-MM-dd'))" "Gray"
        }

        $opening = $p.closing_balance
        $prevEnd = $p.end
    }

    $verified = ($tableRows | Where-Object Status -eq '✅').Count
    $warnings = ($tableRows | Where-Object Status -eq '⚠').Count
    $failed = ($tableRows | Where-Object Status -eq '❌').Count

    Write-Status "`n## $($acct.label) Reconciliation Table" "White"
    Write-Host "| Period End | Opening | Credits | Debits | Net Flow | TAS Closing | Stmt Closing | Diff | Status |"
    Write-Host "|------------|---------|---------|--------|----------|-------------|--------------|------|--------|"
    foreach ($row in $tableRows) {
        Write-Host ("| {0} | {1,8} | {2,7} | {3,6} | {4,8} | {5,10} | {6,10} | {7,5} | {8} |" -f
            $row.PeriodEnd, $row.Opening, $row.Credits, $row.Debits, $row.NetFlow,
            $row.TASClosing, $row.StmtClosing, $row.Diff, $row.Status)
    }
    Write-Status "  ✅ $verified | ⚠ $warnings | ❌ $failed of $($tableRows.Count)" $(if ($failed -eq 0) {'Green'} elseif ($warnings -gt 0) {'Yellow'} else {'Red'})
}

Write-Status "`nOverall: $(if ($allOk) { 'PASS — all periods balance' } else { 'FAIL — some periods have discrepancies' })" $(if ($allOk) {'Green'} else {'Red'})
if ($allOk) { exit 0 } else { exit 1 }
