<#
.SYNOPSIS
    Reconciliation Check for InterSite Consulting and Room Rentals books.
    Runs Balance Forward verification, detects near-duplicates, and compares TAS
    against bank statement CSVs per period.
# Used by: Skills/Bookkeeping/books/reconciliation/reconciliation-prep.md, Skills/Bookkeeping/books/reconciliation/reconciliation-check.md
.DESCRIPTION
    Reads TAS-2026.csv and statement period definitions, then:
      1. Balance Forward check per account per period
      2. Near-duplicate detection (same amount, same account, ±3 days)
      3. Per-period TAS vs bank statement CSV comparison
      4. Summary of verified vs failing periods
.PARAMETER Organization
    Which org to check: "intersite-consulting" (default) or "room-rentals"
.PARAMETER Account
    Optional: single account slug to check (e.g. "RBC-INTERSITE", "MC-6258")
.PARAMETER Detailed
    Show per-period transaction breakdown for failing periods
.PARAMETER FixNearDuplicates
    Remove near-duplicates from TAS and save
#>

param(
    [string]$Organization = "intersite-consulting",
    [string]$Account = "",
    [switch]$Detailed,
    [switch]$FixNearDuplicates
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\$Organization"
$tasPath = "$booksRoot\TAS-2026.csv"
$bankDir = if ($Organization -eq "room-rentals") { "$booksRoot\2026 Bank Statements" } else { "$booksRoot\2026 Filing\2026 Bank Statements" }

if (-not (Test-Path $tasPath)) { Write-Error "TAS not found: $tasPath"; exit 1 }
if (-not (Test-Path $bankDir)) {
    Write-Warning "Bank statements dir not found: $bankDir -- falling back to LocalBooks mode"
    $LocalBooks = $true
}

# --- Account definitions ---
$accounts = @{
    "RBC-INTERSITE" = @{
        label = "RBC Intersite (Chequing 6632)"
        folder = "RBC-INTERSITE"
        isCreditCard = $false
        periods = @(
            @{start='2025-03-13'; end='2025-04-11'; closing=5734.22}
            @{start='2025-04-11'; end='2025-05-13'; closing=4807.32}
            @{start='2025-05-13'; end='2025-06-13'; closing=3648.11}
            @{start='2025-06-13'; end='2025-07-11'; closing=8482.44}
            @{start='2025-07-11'; end='2025-08-13'; closing=5941.26}
            @{start='2025-08-13'; end='2025-09-12'; closing=5374.15}
            @{start='2025-09-12'; end='2025-10-10'; closing=5156.95}
            @{start='2025-10-10'; end='2025-11-13'; closing=4416.33}
            @{start='2025-11-13'; end='2025-12-12'; closing=4863.74}
            @{start='2025-12-12'; end='2026-01-13'; closing=6072.59}
            @{start='2026-01-13'; end='2026-02-13'; closing=4756.72}
            @{start='2026-02-13'; end='2026-03-13'; closing=4535.77}
            @{start='2026-03-13'; end='2026-04-13'; closing=4202.62}
            @{start='2026-04-13'; end='2026-05-13'; closing=4146.16}
        )
    }
    "MC-6258" = @{
        label = "MC 6258 (MasterCard 6241)"
        folder = "MC 6241 (6258)"
        isCreditCard = $true
        periods = @(
            @{start='2025-03-11'; end='2025-04-09'; closing=1282.78}
            @{start='2025-04-10'; end='2025-05-09'; closing=64.56}
            @{start='2025-05-10'; end='2025-06-09'; closing=798.05}
            @{start='2025-06-10'; end='2025-07-09'; closing=79.17}
            @{start='2025-07-10'; end='2025-08-11'; closing=1165.17}
            @{start='2025-08-12'; end='2025-09-09'; closing=144.93}
            @{start='2025-09-10'; end='2025-10-09'; closing=360.73}
            @{start='2025-10-10'; end='2025-11-10'; closing=158.75}
            @{start='2025-11-11'; end='2025-12-09'; closing=85.41}
            @{start='2025-12-10'; end='2026-01-09'; closing=373.45}
            @{start='2026-01-10'; end='2026-02-09'; closing=1814.09}
            @{start='2026-02-10'; end='2026-03-09'; closing=26.66}
            @{start='2026-03-10'; end='2026-04-09'; closing=21.30}
            @{start='2026-04-10'; end='2026-05-11'; closing=194.36}
        )
    }
    # ── Room-rentals accounts ──────────────────────────────────
    "RBC-FRA" = @{
        label = "RBC-FRA 5172549"
        folder = "RBC-FRA-5172549"
        isCreditCard = $false
        periods = @(
            @{start='2025-12-19'; end='2026-01-21'; closing=1702.25}
            @{start='2026-01-21'; end='2026-02-20'; closing=4121.72}
            @{start='2026-02-20'; end='2026-03-20'; closing=1834.50}
            @{start='2026-03-20'; end='2026-04-21'; closing=2890.08}
            @{start='2026-04-21'; end='2026-05-21'; closing=4115.75}
        )
    }
    "TD-MLM" = @{
        label = "TD-MLM 6467010"
        folder = "TD-MLM-6467010"
        isCreditCard = $false
        periods = @(
            @{start='2025-11-28'; end='2025-12-31'; closing=4378.25}
            @{start='2026-01-30'; end='2026-02-27'; closing=3159.02}
            @{start='2026-02-27'; end='2026-03-31'; closing=5090.89}
            @{start='2026-03-31'; end='2026-04-30'; closing=4247.06}
            @{start='2026-04-30'; end='2026-05-29'; closing=4496.21}
        )
    }
    "SCOTIA-TMH" = @{
        label = "SCOTIA-TMH 406000697486"
        folder = "SCOTIA-TMH 406000697486"
        isCreditCard = $false
        periods = @(
            @{start='2025-12-21'; end='2026-01-20'; closing=2875.72}
            @{start='2026-01-21'; end='2026-02-20'; closing=4143.80}
            @{start='2026-02-21'; end='2026-03-20'; closing=5460.99}
            @{start='2026-03-21'; end='2026-04-20'; closing=6920.10}
            @{start='2026-04-21'; end='2026-05-20'; closing=5642.10}
        )
    }
    "RBC-VISA" = @{
        label = "RBC-FRA-6679 Visa"
        folder = "RBC-FRA-6679"
        isCreditCard = $true
        periods = @(
            @{start='2025-12-10'; end='2026-01-09'; closing=81.28}
            @{start='2026-01-10'; end='2026-02-09'; closing=188.12}
            @{start='2026-02-10'; end='2026-03-09'; closing=64.25}
            @{start='2026-03-10'; end='2026-04-09'; closing=2.11}
            @{start='2026-04-10'; end='2026-05-11'; closing=55.95}
            @{start='2026-05-12'; end='2026-06-09'; closing=180.32}
        )
    }
}

# --- Parse TAS ---
$lines = Get-Content $tasPath
$dataStart = 0
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -notmatch '^#') { $dataStart = $i; break } }
$dataLines = $lines[($dataStart + 1)..($lines.Count - 1)]

function Convert-Date($rawDate) {
    if ($rawDate -match '^\d{4}-\d{2}-\d{2}$') { return $rawDate }
    $parts = $rawDate -split '/'
    if ($parts.Count -eq 3) {
        $m = [int]$parts[0]; $d = [int]$parts[1]; $y = [int]$parts[2]
        if ($y -ge 2000 -and $y -le 2099 -and $m -ge 1 -and $m -le 12 -and $d -ge 1 -and $d -le 31) {
            return '{0:D4}-{1:D2}-{2:D2}' -f $y, $m, $d
        }
    }
    return $rawDate
}
$allTxns = @()
foreach ($line in $dataLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $cols = $line -split ','
    $allTxns += [PSCustomObject]@{
        date = Convert-Date ($cols[0].Trim('"'))
        account = $cols[1].Trim('"')
        amount = [double]$cols[2].Trim('"')
        desc = $cols[3].Trim('"')
        source = $cols[7].Trim('"')
    }
}

# --- Helpers ---
function Write-Status($text, $color) { Write-Host $text -ForegroundColor $color }

function Get-AcctTxns($acctLabel) {
    $allTxns | Where-Object { $_.account -eq $acctLabel }
}

function Get-StmtTxns($acctFolder, $periodStart, $periodEnd) {
    $stmtDir = "$bankDir\$acctFolder"
    $stmtFile = Get-ChildItem "$stmtDir\*$periodEnd.csv" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Zoho' -and $_.Name -notmatch 'dry-run' } | Select-Object -First 1
    if (-not $stmtFile) { return $null }
    $rows = Get-Content $stmtFile.FullName | Where-Object { $_ -notmatch '^#' -and $_ -match '\d{4}-\d{2}-\d{2}' }
    $txns = @()
    foreach ($l in $rows) {
        $cols = $l -split ','
        if ($cols.Count -lt 5) { continue }
        try {
            $amt = [double]$cols[4].Trim('"')
            $dc = $cols[3].Trim('"')
            $signed = if ($dc -eq 'debit' -or $dc -eq 'Debit') { -$amt } else { $amt }
            $txns += [PSCustomObject]@{ date = $cols[0].Trim('"'); payee = $cols[1].Trim('"'); desc = $cols[2].Trim('"'); amount = $signed; dc = $dc }
        } catch {}
    }
    $txns
}

function Test-BalanceForward($Periods, $Txns, $IsCreditCard) {
    $results = @(); $verified = 0; $warnings = 0; $failed = 0
    $prevEnd = $null
    for ($i = 0; $i -lt $Periods.Count; $i++) {
        $p = $Periods[$i]
        if ($i -eq 0) {
            $netFlow = ($Txns | Where-Object { $_.date -ge $p.start -and $_.date -le $p.end } | Measure-Object amount -Sum).Sum
        } else {
            $netFlow = ($Txns | Where-Object { $_.date -gt $prevEnd -and $_.date -le $p.end } | Measure-Object amount -Sum).Sum
        }
        if (-not $netFlow) { $netFlow = 0 }
        if ($i -eq 0) {
            $opening = if ($IsCreditCard) { [math]::Round($p.closing + $netFlow, 2) } else { [math]::Round($p.closing - $netFlow, 2) }
        }
        $tasClosing = if ($IsCreditCard) { [math]::Round($opening - $netFlow, 2) } else { [math]::Round($opening + $netFlow, 2) }
        $diff = [math]::Round($tasClosing - $p.closing, 2)
        $abs = [math]::Abs($diff)
        $status = if ($abs -le 0.02) { $verified++; '✅' } elseif ($abs -le 50) { $warnings++; '⚠' } else { $failed++; '❌' }
        $results += [PSCustomObject]@{
            PeriodLabel = "$($p.start) to $($p.end)"
            Opening = if ($i -eq 0) { $opening } else { $Periods[$i-1].closing }
            NetFlow = $netFlow
            TASClosing = $tasClosing; StmtClosing = $p.closing
            Diff = $diff; Status = $status
        }
        $opening = $p.closing
        $prevEnd = $p.end
    }
    return $results, $verified, $warnings, $failed
}

function Find-NearDuplicates($Txns) {
    $dupes = @()
    $done = @{}
    for ($i = 0; $i -lt $Txns.Count; $i++) {
        for ($j = $i + 1; $j -lt $Txns.Count; $j++) {
            if ($Txns[$i].amount -ne $Txns[$j].amount) { continue }
            $span = [math]::Abs(((Get-Date $Txns[$i].date) - (Get-Date $Txns[$j].date)).TotalDays)
            if ($span -gt 0 -and $span -le 3) {
                $key = @($Txns[$i].date, $Txns[$i].amount, $Txns[$j].date) -join '|'
                $rKey = @($Txns[$j].date, $Txns[$j].amount, $Txns[$i].date) -join '|'
                if (-not $done.ContainsKey($key) -and -not $done.ContainsKey($rKey)) {
                    $dupes += [PSCustomObject]@{
                        amount = $Txns[$i].amount
                        date1 = $Txns[$i].date; desc1 = $Txns[$i].desc
                        date2 = $Txns[$j].date; desc2 = $Txns[$j].desc
                        spanDays = [math]::Round($span, 0)
                    }
                    $done[$key] = $true
                }
            }
        }
    }
    $dupes
}

# --- Filter by organization ---
$orgAccountKeys = switch ($Organization) {
    "intersite-consulting" { @("RBC-INTERSITE", "MC-6258") }
    "room-rentals"         { @("RBC-FRA", "TD-MLM", "SCOTIA-TMH", "RBC-VISA") }
    default                { Write-Error "Unknown organization: $Organization"; exit 1 }
}
$filteredAccounts = [ordered]@{}
foreach ($key in $orgAccountKeys) {
    if ($accounts.ContainsKey($key)) { $filteredAccounts[$key] = $accounts[$key] }
}

# --- Main ---
$targetAccounts = if ($Account) { @($filteredAccounts[$Account]) } else { $filteredAccounts.Values }

if ($LocalBooks) {
    Write-Status "LocalBooks mode: using TAS balance-forward only (no sidecar/CSV comparison)" "Yellow"
}

foreach ($acct in $targetAccounts) {
    $txns = Get-AcctTxns $acct.label
    Write-Status "`n══════════════════════════════════════════" "Cyan"
    Write-Status "  $($acct.label)" "Cyan"
    Write-Status "══════════════════════════════════════════" "Cyan"

    # 1. Balance Forward
    Write-Status "`n1. Balance Forward Check:" "Yellow"
    $bf, $v, $w, $f = Test-BalanceForward $acct.periods $txns $acct.isCreditCard
    $bf | Select-Object PeriodLabel, Opening, NetFlow, TASClosing, StmtClosing, Diff, Status | Format-Table -AutoSize
    Write-Status "   ✅ $v | ⚠ $w | ❌ $f of $($bf.Count)" $(if ($f -eq 0) {'Green'} elseif ($w -gt 0) {'Yellow'} else {'Red'})

    # 2. Near-duplicates
    Write-Status "`n2. Near-Duplicate Check (same amount, ±3 days):" "Yellow"
    $dupes = Find-NearDuplicates $txns
    if ($dupes.Count -gt 0) {
        $dupes | Sort-Object amount | Format-Table amount, date1, desc1, date2, desc2, spanDays -AutoSize
        $total = ($dupes | ForEach-Object { [math]::Abs($_.amount) } | Measure-Object -Sum).Sum
        Write-Status "   $($dupes.Count) near-duplicates found totaling $total" "Yellow"
    } else {
        Write-Status "   No near-duplicates found" "Green"
    }

    # 3. Per-period comparison (failing periods only)
    if ($Detailed) {
        Write-Status "`n3. Detailed Period Comparison:" "Yellow"
        $failingPeriods = $bf | Where-Object Status -ne '✅'
        $prevEndDetailed = $null
        for ($pi = 0; $pi -lt $acct.periods.Count; $pi++) {
            $p = $acct.periods[$pi]
            $fp = $bf[$pi]
            if ($fp.Status -eq '✅') { $prevEndDetailed = $p.end; continue }
            
            $start = $p.start; $end = $p.end
            if ($pi -eq 0) {
                $tasPeriodTxns = $txns | Where-Object { $_.date -ge $start -and $_.date -le $end }
            } else {
                $tasPeriodTxns = $txns | Where-Object { $_.date -gt $prevEndDetailed -and $_.date -le $end }
            }
            $stmtTxns = Get-StmtTxns $acct.folder $start $end
            $prevEndDetailed = $end
            Write-Status "   Period $($fp.PeriodLabel): Diff=$($fp.Diff)" "White"
            if ($stmtTxns -and $tasPeriodTxns.Count -ne $stmtTxns.Count) {
                Write-Status "     TAS: $($tasPeriodTxns.Count) txns, Stmt: $($stmtTxns.Count) txns" "Gray"
                
                # Compare
                foreach ($t in $tasPeriodTxns) {
                    $matchStmt = $stmtTxns | Where-Object { [math]::Abs($_.amount - $t.amount) -lt 0.01 -and $_.date -eq $t.date }
                    if (-not $matchStmt) {
                        Write-Status "     TAS only: $($t.date)  $($t.amount)  $($t.desc)" "Yellow"
                    }
                }
                foreach ($s in $stmtTxns) {
                    $matchTas = $tasPeriodTxns | Where-Object { [math]::Abs($_.amount - $s.amount) -lt 0.01 -and $_.date -eq $s.date }
                    if (-not $matchTas) {
                        Write-Status "     Stmt only: $($s.date)  $($s.amount)  $($s.payee)" "Red"
                    }
                }
            }
        }
    }
}

Write-Status "`nDone." "Green"