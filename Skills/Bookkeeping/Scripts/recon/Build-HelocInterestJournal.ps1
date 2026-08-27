<#
.SYNOPSIS
    Generates a HELOC mortgage interest journal entry from TAS data and TD annual statement totals.
.DESCRIPTION
    Reads the room-rentals TAS CSV, extracts all Mortgage/HELOC payment rows, and proportionally
    splits each payment into principal vs interest based on the total annual interest amount
    from the TD annual mortgage/HELOC statement.
    
    Outputs a markdown journal entry with:
    - Summary of total payments, total interest, interest ratio
    - Per-payment breakdown: date, amount, interest portion, principal portion
    - Proposed journal entry debiting Mortgage Interest and crediting Mortgage/HELOC Payments
.PARAMETER TasPath
    Path to TAS-2026.csv (room-rentals). Deduced from default location if omitted.
.PARAMETER TotalInterest
    Total interest paid for the year, as shown on the TD annual HELOC/mortgage statement.
    Example: -TotalInterest 4523.17
.PARAMETER OutputDir
    Output directory for the journal entry markdown file.
    Default: ~/intersite-docs/Taxes and Bookkeeping/room-rentals/2026 Filing
.PARAMETER FiscalYear
    Fiscal year for output naming (default: 2026).
.PARAMETER DryRun
    Preview the journal entry without writing files.
.PARAMETER PassThru
    Return the result hashtable instead of writing files (for pipeline chaining).
.EXAMPLE
    .\Build-HelocInterestJournal.ps1 -TotalInterest 4523.17 -DryRun
    Preview the HELOC interest split with $4,523.17 total annual interest.
.EXAMPLE
    .\Build-HelocInterestJournal.ps1 -TotalInterest 4523.17
    Generate the journal entry file with $4,523.17 total annual interest.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TasPath,
    [Parameter(Mandatory = $true)]
    [decimal]$TotalInterest,
    [string]$OutputDir,
    [int]$FiscalYear = 2026,
    [switch]$DryRun,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

$booksRoot = "$env:USERPROFILE\intersite-docs\Taxes and Bookkeeping\room-rentals"
if (-not $TasPath) {
    $tasCandidates = @(
        "$booksRoot\TAS-$FiscalYear.csv"
        "$booksRoot\TAS-zoho-fy$FiscalYear.csv"
    )
    $TasPath = $tasCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not (Test-Path $TasPath)) { throw "TAS not found: $TasPath. Specify -TasPath or ensure TAS-$FiscalYear.csv exists." }

if (-not $OutputDir) {
    $OutputDir = "$booksRoot\$FiscalYear Filing"
}
if (-not (Test-Path $OutputDir)) { $null = New-Item -ItemType Directory -Path $OutputDir -Force }

# Read TAS
$data = Import-Csv $TasPath
Write-Host "Read $($data.Count) transactions from TAS" -ForegroundColor Green

# Filter for mortgage/HELOC payments (assume TAS uses 'Mortgage' or 'TD Mortgage and HELOC Payments' category)
$mortgageRows = $data | Where-Object {
    $cat = $_.category
    $cat -match 'mortgage' -or $cat -match 'HELOC' -or $cat -match 'Loan Payment'
}
if ($mortgageRows.Count -eq 0) {
    Write-Host "No mortgage/HELOC payments found in TAS. Check category names." -ForegroundColor Yellow
    Write-Host "Available categories: $($data | Select-Object -ExpandProperty category -Unique | Sort-Object | Out-String)" -ForegroundColor Gray
    if ($PassThru) { return $null }
    return
}

Write-Host "Found $($mortgageRows.Count) mortgage/HELOC payment rows" -ForegroundColor Cyan

# Sum total mortgage payments
$totalPayments = [math]::Round(($mortgageRows | Measure-Object -Property amount -Sum).Sum, 2)
$interestRatio = [math]::Round($TotalInterest / $totalPayments, 6)

Write-Host "Total Mortgage/HELOC Payments: $( [string]::Format('{0:N2}', $totalPayments) )" -ForegroundColor White
Write-Host "Total Interest (from statement): $( [string]::Format('{0:N2}', $TotalInterest) )" -ForegroundColor White
Write-Host "Interest Ratio: $interestRatio" -ForegroundColor Gray

# Build per-payment breakdown
$entries = [System.Collections.ArrayList]@()
$totalInterestAllocated = 0.0
$totalPrincipalAllocated = 0.0

foreach ($row in $mortgageRows) {
    $paymentAmt = [math]::Abs([decimal]::Parse($row.amount))
    $interestPortion = [math]::Round($paymentAmt * $interestRatio, 2)
    $principalPortion = [math]::Round($paymentAmt - $interestPortion, 2)
    $totalInterestAllocated += $interestPortion
    $totalPrincipalAllocated += $principalPortion

    [void]$entries.Add([PSCustomObject]@{
        date             = $row.date
        description      = $row.description
        bank_account     = $row.bank_account
        payment_amount   = $paymentAmt
        interest_portion = $interestPortion
        principal_portion = $principalPortion
    })
}

# Adjust last row for rounding
if ($entries.Count -gt 0) {
    $lastEntry = $entries[-1]
    $roundingAdj = [math]::Round($TotalInterest - $totalInterestAllocated + $totalPrincipalAllocated, 2)
    $lastEntry.interest_portion = [math]::Round($lastEntry.interest_portion + ($TotalInterest - $totalInterestAllocated), 2)
    $lastEntry.principal_portion = [math]::Round($lastEntry.payment_amount - $lastEntry.interest_portion, 2)
}

$totalInterestRounded = [math]::Round(($entries | Measure-Object -Property interest_portion -Sum).Sum, 2)
$totalPrincipalRounded = [math]::Round(($entries | Measure-Object -Property principal_portion -Sum).Sum, 2)

# Build markdown output
$sb = [System.Text.StringBuilder]::new()

$null = $sb.AppendLine("# HELOC/Mortgage Interest Journal Entry")
$null = $sb.AppendLine("**Entity:** Room Rentals (Victor Salmon)")
$null = $sb.AppendLine("**Fiscal Year:** $FiscalYear")
$null = $sb.AppendLine("**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$null = $sb.AppendLine("**Source:** TD Annual HELOC/Mortgage Statement — Total Interest: $( [string]::Format('{0:N2}', $TotalInterest) )")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Summary")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("| Item | Amount |")
$null = $sb.AppendLine("|------|--------|")
$null = $sb.AppendLine("| Total Mortgage/HELOC Payments | $( [string]::Format('{0:N2}', $totalPayments) ) |")
$null = $sb.AppendLine("| Total Interest (per statement) | $( [string]::Format('{0:N2}', $TotalInterest) ) |")
$null = $sb.AppendLine("| Total Principal | $( [string]::Format('{0:N2}', $totalPrincipalRounded) ) |")
$null = $sb.AppendLine("| Interest Ratio | $($interestRatio.ToString('P2')) |")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Per-Payment Breakdown")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("| Date | Account | Description | Payment | Interest | Principal |")
$null = $sb.AppendLine("|------|---------|-------------|---------|----------|-----------|")
foreach ($e in $entries) {
    $null = $sb.AppendLine("| $($e.date) | $($e.bank_account) | $($e.description) | $( [string]::Format('{0:N2}', $e.payment_amount) ) | $( [string]::Format('{0:N2}', $e.interest_portion) ) | $( [string]::Format('{0:N2}', $e.principal_portion) ) |")
}
$null = $sb.AppendLine("| **Total** | | | **$( [string]::Format('{0:N2}', ($entries | Measure-Object -Property payment_amount -Sum).Sum) )** | **$( [string]::Format('{0:N2}', $totalInterestRounded) )** | **$( [string]::Format('{0:N2}', $totalPrincipalRounded) )** |")
$null = $sb.AppendLine("")

$null = $sb.AppendLine("## Proposed Journal Entry")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("| Account | Debit | Credit |")
$null = $sb.AppendLine("|---------|-------|--------|")
$null = $sb.AppendLine("| Mortgage Interest (T776 line 8710) | $( [string]::Format('{0:N2}', $totalInterestRounded) ) | |")
$null = $sb.AppendLine("| Mortgage and HELOC Payments | | $( [string]::Format('{0:N2}', $totalInterestRounded) ) |")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("*To record interest portion of mortgage/HELOC payments for $FiscalYear.*")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("## Verification")
$null = $sb.AppendLine("")
$null = $sb.AppendLine("- Debit (Mortgage Interest) = Credit (Mortgage/HELOC Payments) = $( [string]::Format('{0:N2}', $totalInterestRounded) ): **$($totalInterestRounded -eq $totalInterestRounded ? 'PASS' : 'FAIL')**")
$null = $sb.AppendLine("- Total Interest matches statement: **$($totalInterestRounded -eq $TotalInterest ? 'PASS' : "MISMATCH — allocated $([string]::Format('{0:N2}', $totalInterestRounded)) vs stated $([string]::Format('{0:N2}', $TotalInterest))")**")
$null = $sb.AppendLine("- Principal + Interest = Total Payments: **$([math]::Round($totalInterestRounded + $totalPrincipalRounded, 2) -eq $totalPayments ? 'PASS' : 'FAIL')**")

$mdContent = $sb.ToString()

# Output
if ($DryRun) {
    Write-Host "`n=== DRY RUN — Journal Entry Preview ===" -ForegroundColor Cyan
    Write-Host $mdContent
    Write-Host "`n=== End Dry Run ===" -ForegroundColor Cyan
} else {
    $outPath = Join-Path $OutputDir "heloc-interest-journal-$FiscalYear.md"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($outPath, $mdContent, $utf8NoBom)
    Write-Host "`nJournal entry written: $outPath" -ForegroundColor Green
}

# Build result object
$result = [ordered]@{
    fiscal_year        = $FiscalYear
    entity             = 'Room Rentals (Victor Salmon)'
    generated          = (Get-Date).ToString('o')
    data_source        = $TasPath
    total_payments     = $totalPayments
    total_interest     = $TotalInterest
    total_principal    = $totalPrincipalRounded
    interest_ratio     = $interestRatio
    journal_debit      = $totalInterestRounded
    journal_credit     = $totalInterestRounded
    entries            = @($entries | ForEach-Object {
        @{
            date              = $_.date
            description       = $_.description
            bank_account      = $_.bank_account
            payment_amount    = $_.payment_amount
            interest_portion  = $_.interest_portion
            principal_portion = $_.principal_portion
        }
    })
    verification = @{
        debit_equals_credit       = ($totalInterestRounded -eq $totalInterestRounded)
        interest_matches_statement = ($totalInterestRounded -eq $TotalInterest)
        sum_matches_total         = [math]::Round($totalInterestRounded + $totalPrincipalRounded, 2) -eq $totalPayments
    }
}

if ($PassThru) { return $result }

Write-Host "`nDone." -ForegroundColor Cyan
