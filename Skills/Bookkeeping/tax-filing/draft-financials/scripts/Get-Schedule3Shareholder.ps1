<#
.SYNOPSIS
    Computes T2 Schedule 3 — Shareholder Information (loan activity + dividends).
.DESCRIPTION
    Takes shareholder loan opening balance, advances, repayments, and dividends paid
    to produce structured Schedule 3 data. If a CSV of SHL transactions is provided,
    advances and repayments are calculated automatically.

    Accounting convention: Advances (debits) increase the loan to shareholder;
    Repayments (credits) decrease it. A positive closing balance means the
    shareholder owes the company (debit balance — reportable on Schedule 3).
    A negative closing balance means the company owes the shareholder (credit
    balance — no Schedule 3 issue).
.PARAMETER OpeningBalance
    Shareholder loan balance at start of fiscal year (from prior year T2 / NOA).
.PARAMETER AdvancesTotal
    Total advances to shareholder during the year (debits). Optional if CSV provided.
.PARAMETER RepaymentsTotal
    Total repayments from shareholder during the year (credits). Optional if CSV provided.
.PARAMETER DividendsTotal
    Total non-eligible dividends paid during the year.
.PARAMETER SHLCSV
    Path to a CSV of Shareholder Loan transactions (columns: type, amount).
    type = "advance" or "repayment". Alternative to AdvancesTotal/RepaymentsTotal.
.PARAMETER EntityName
    Entity name override (optional, defaults to config value).
.EXAMPLE
    $s3 = .\Get-Schedule3Shareholder.ps1 -OpeningBalance 5000 -AdvancesTotal 12000 -RepaymentsTotal 8000 -DividendsTotal 15000
.EXAMPLE
    $s3 = .\Get-Schedule3Shareholder.ps1 -OpeningBalance 5000 -SHLCSV "C:\data\shl-transactions.csv" -DividendsTotal 15000
#>
function Get-Schedule3Shareholder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [decimal]$OpeningBalance,

        [decimal]$AdvancesTotal,

        [decimal]$RepaymentsTotal,

        [Parameter(Mandatory)]
        [decimal]$DividendsTotal,

        [string]$SHLCSV,

        [string]$EntityName
    )

    $advances  = $AdvancesTotal
    $repayments = $RepaymentsTotal

    if ($SHLCSV) {
        if (-not (Test-Path $SHLCSV)) { throw "SHL CSV not found: $SHLCSV" }
        $txns = Import-Csv $SHLCSV
        $advances  = [decimal]($txns | Where-Object { $_.type -eq "advance" } | ForEach-Object { [decimal]$_.amount } | Measure-Object -Sum).Sum
        $repayments = [decimal]($txns | Where-Object { $_.type -eq "repayment" } | ForEach-Object { [decimal]$_.amount } | Measure-Object -Sum).Sum
    }

    $closingBalance = $OpeningBalance + $advances - $repayments

    return [PSCustomObject]@{
        opening_balance     = [math]::Round($OpeningBalance, 2, [MidpointRounding]::AwayFromZero)
        advances_during_year = [math]::Round($advances, 2, [MidpointRounding]::AwayFromZero)
        repayments_during_year = [math]::Round($repayments, 2, [MidpointRounding]::AwayFromZero)
        balance_before_repayments = [math]::Round($OpeningBalance + $advances, 2, [MidpointRounding]::AwayFromZero)
        closing_balance     = [math]::Round($closingBalance, 2, [MidpointRounding]::AwayFromZero)
        non_eligible_dividends = [math]::Round($DividendsTotal, 2, [MidpointRounding]::AwayFromZero)

        schedule_lines = [PSCustomObject]@{
            line_170 = [math]::Round($OpeningBalance, 2, [MidpointRounding]::AwayFromZero)
            line_171_175 = [math]::Round($advances, 2, [MidpointRounding]::AwayFromZero)
            line_180 = [math]::Round($OpeningBalance + $advances, 2, [MidpointRounding]::AwayFromZero)
            line_181_185 = [math]::Round($repayments, 2, [MidpointRounding]::AwayFromZero)
            line_186 = [math]::Round($closingBalance, 2, [MidpointRounding]::AwayFromZero)
            line_270 = [math]::Round($DividendsTotal, 2, [MidpointRounding]::AwayFromZero)
        }

        note = if ($closingBalance -gt 0) {
            "Shareholder owes company (debit balance of $([math]::Round($closingBalance, 2, [MidpointRounding]::AwayFromZero))) - report on Schedule 3 as amount owing"
        } elseif ($closingBalance -lt 0) {
            "Company owes shareholder (credit balance of $([math]::Round(-$closingBalance, 2, [MidpointRounding]::AwayFromZero))) - no Schedule 3 issue"
        } else {
            "Shareholder loan balance is zero"
        }
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-Schedule3Shareholder') {
    Get-Schedule3Shareholder -OpeningBalance 5000 -AdvancesTotal 12000 -RepaymentsTotal 8000 -DividendsTotal 15000
}

