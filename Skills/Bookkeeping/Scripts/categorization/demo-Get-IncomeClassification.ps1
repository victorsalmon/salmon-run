<#
.SYNOPSIS
    Demo — exercises Get-IncomeClassification against sample credit scenarios.
#>

$scriptDir = Split-Path $PSCommandPath -Parent
. (Join-Path $scriptDir "Get-IncomeClassification.ps1")

$testCases = @(
    # Income scenarios
    @{ Vendor = "WAVE SV9T";                Description = "payment processing";    Amount = 850.00 }
    @{ Vendor = "WAVE SV9T - CLIENT NAME";  Description = "";                     Amount = 1234.56 }
    @{ Vendor = "ONLINE BANKING TRANSFER";  Description = "CLIENT NAME rent";     Amount = 183.75 }
    @{ Vendor = "ONLINE BANKING TRANSFER";  Description = "ABC Corp invoice";     Amount = 2750.50 }
    @{ Vendor = "UPS HAVENS";              Description = "consulting";            Amount = 500.00 }
    @{ Vendor = "UPS HAVENS";              Description = "";                      Amount = 250.00 }

    # Interest
    @{ Vendor = "INTEREST EARNED";          Description = "monthly interest";     Amount = 1.23 }
    @{ Vendor = "INTEREST PAID";            Description = "savings account";      Amount = 0.89 }
    @{ Vendor = "INT INCOME";               Description = "";                     Amount = 2.50 }

    # Internal transfers (not income)
    @{ Vendor = "ONLINE BANKING TRANSFER";  Description = "VISA CREDIT CARD";     Amount = 500.00 }
    @{ Vendor = "ONLINE BANKING TRANSFER";  Description = "MASTERCARD";           Amount = 250.00 }
    @{ Vendor = "PAYMENT - THANK YOU";      Description = "online banking";       Amount = 1000.00 }
    @{ Vendor = "AUTOMATIC PAYMENT";        Description = "RBC CREDIT";           Amount = 750.00 }

    # Shareholder loan / owner contributions
    @{ Vendor = "E-TRANSFER AUTODEPOSIT";   Description = "VICTOR SALMON";        Amount = 2000.00 }
    @{ Vendor = "E-TRANSFER AUTODEPOSIT";   Description = "from savings";         Amount = 500.00 }
    @{ Vendor = "E-TRANSFER AUTODEPOSIT";   Description = "VAS contribution";     Amount = 1500.00 }

    # Exclude scenarios
    @{ Vendor = "TAX REFUND";               Description = "CRA refund";           Amount = 1200.00 }
    @{ Vendor = "CASH BACK";                Description = "credit card reward";   Amount = 50.00 }
    @{ Vendor = "ATM DEPOSIT";              Description = "";                     Amount = 300.00 }
    @{ Vendor = "PAD CCRA";                 Description = "CANADA REVENUE";       Amount = 850.00 }

    # Generic income via rules
    @{ Vendor = "PETRO-CANADA";             Description = "fuel refund";          Amount = 45.00 }
    @{ Vendor = "AMAZON.CA";                Description = "refund";               Amount = 29.99 }
    @{ Vendor = "UNKNOWN CLIENT PAYMENT";   Description = "";                     Amount = 150.00 }
)

Write-Host ("{0,-40} {1,-25} {2,-10} {3,-25} {4}" -f "Vendor / Description", "Account Name", "Type", "Account ID", "Rule Source") -ForegroundColor Cyan
Write-Host ("=" * 130) -ForegroundColor Cyan

foreach ($tc in $testCases) {
    $r = Get-IncomeClassification -Vendor $tc.Vendor -Description $tc.Description -Amount $tc.Amount

    $typeColor = switch ($r.income_type) {
        "Income"   { "Green" }
        "Transfer" { "Yellow" }
        "Exclude"  { "Gray" }
        "Expense"  { "Red" }
        "Review"   { "Magenta" }
        default    { "Gray" }
    }

    $vendorDisplay = "$($tc.Vendor)"
    if ($tc.Description) { $vendorDisplay += " / $($tc.Description)" }

    Write-Host ("{0,-40} {1,-25} {2,-10} {3,-25} {4}" -f $vendorDisplay, $r.account_name, $r.income_type, $r.account_id, $r.rule_source) -ForegroundColor $typeColor
}

Write-Host "`nKey:" -ForegroundColor Cyan
Write-Host "  Income    → POST /banktransactions type=deposit (income account → bank)" -ForegroundColor Green
Write-Host "  Transfer  → route to liability/equity (no P&L impact)" -ForegroundColor Yellow
Write-Host "  Exclude   → route to Exclude account" -ForegroundColor Gray
Write-Host "  Expense   → POST /expenses (refunds routed to original expense category)" -ForegroundColor Red
Write-Host "  Review    → needs user review (unmatched credit)" -ForegroundColor Magenta
Write-Host "`nDone." -ForegroundColor Cyan
