#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $scriptPath = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\categorization\Get-AccountIdFromRules.ps1"
    . $scriptPath
    $incomeScriptPath = Join-Path $repoRoot "Skills\Bookkeeping\Scripts\categorization\Get-IncomeClassification.ps1"
    . $incomeScriptPath
}

Describe "Get-AccountIdFromRules description_overrides" -Tag "Bookkeeping", "Categorization" {
    It "WAVE SV9T maps to Consulting Revenue" {
        $result = Get-AccountIdFromRules -Vendor "WAVE SV9T" -Description "payment processing" -PassThru
        $result.account_id | Should -Be "93310000000149102"
        $result.rule_source | Should -Be "description_override"
    }
    It "WAVE PRO maps to Software and IT Expenses" {
        $result = Get-AccountIdFromRules -Vendor "WAVE PRO" -PassThru
        $result.account_id | Should -Be "93310000000000427"
        $result.rule_source | Should -Be "description_override"
    }
    It "REINVEST WEALTH maps to Software and IT Expenses" {
        $result = Get-AccountIdFromRules -Vendor "ReInvest Wealth Inc" -Description "REINVEST WEALTH subscription" -PassThru
        $result.account_id | Should -Be "93310000000000427"
        $result.rule_source | Should -Be "description_override"
    }
}

Describe "Get-AccountIdFromRules vendor keyword rules for fuel" -Tag "Bookkeeping", "Categorization" {
    It "Petro-Canada maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Petro-Canada" | Should -Be "93310000000000424"
    }
    It "Shell maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Shell" | Should -Be "93310000000000424"
    }
    It "Chevron maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Chevron" | Should -Be "93310000000000424"
    }
    It "Super Save Gas maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Super Save Gas" | Should -Be "93310000000000424"
    }
    It "CO-OP maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "CO-OP Vernon" | Should -Be "93310000000000424"
    }
    It "CHV prefix maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "CHV1234" | Should -Be "93310000000000424"
    }
}

Describe "Get-AccountIdFromRules vendor keyword rules for auto repair" -Tag "Bookkeeping", "Categorization" {
    It "Kal Tire maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Kal Tire" | Should -Be "93310000000000424"
    }
    It "Lordco maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Lordco Auto Parts" | Should -Be "93310000000000424"
    }
    It "ICBC maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "ICBC" | Should -Be "93310000000000424"
    }
    It "Impark maps to Automobile Expense" {
        Get-AccountIdFromRules -Vendor "Impark" | Should -Be "93310000000000424"
    }
}

Describe "Get-AccountIdFromRules vendor keyword rules for software IT" -Tag "Bookkeeping", "Categorization" {
    It "Zoho maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "Zoho Canada" | Should -Be "93310000000000427"
    }
    It "InterServer maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "InterServer" | Should -Be "93310000000000427"
    }
    It "Kilo Code maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "Kilo Code" | Should -Be "93310000000000427"
    }
    It "Anomaly maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "Anomaly" | Should -Be "93310000000000427"
    }
    It "OpenRouter maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "OpenRouter Inc" | Should -Be "93310000000000427"
    }
    It "Squarespace maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "Squarespace" | Should -Be "93310000000000427"
    }
    It "Namecheap maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "Namecheap" | Should -Be "93310000000000427"
    }
    It "Freedom Mobile maps to Software and IT Expenses" {
        Get-AccountIdFromRules -Vendor "Freedom Mobile" | Should -Be "93310000000000427"
    }
}

Describe "Get-AccountIdFromRules vendor keyword rules for repairs" -Tag "Bookkeeping", "Categorization" {
    It "Home Depot maps to Repairs and Maintenance" {
        Get-AccountIdFromRules -Vendor "Home Depot" | Should -Be "93310000000000457"
    }
    It "Vernon Lock maps to Repairs and Maintenance" {
        Get-AccountIdFromRules -Vendor "Vernon Lock" | Should -Be "93310000000000457"
    }
    It "Temu maps to Repairs and Maintenance" {
        Get-AccountIdFromRules -Vendor "Temu" | Should -Be "93310000000000457"
    }
}

Describe "Get-AccountIdFromRules vendor keyword rules for banking" -Tag "Bookkeeping", "Categorization" {
    It "Monthly Account Fee maps to Bank Fees" {
        Get-AccountIdFromRules -Vendor "Monthly Account Fee" | Should -Be "93310000000000409"
    }
    It "Purchase Interest maps to Bank Fees" {
        Get-AccountIdFromRules -Vendor "Purchase Interest" | Should -Be "93310000000000409"
    }
    It "Automatic Payment maps to Credit Card Payments" {
        Get-AccountIdFromRules -Vendor "Automatic Payment" | Should -Be "93310000000300002"
    }
    It "Payment Thank You maps to Credit Card Payments" {
        Get-AccountIdFromRules -Vendor "Payment - Thank You" | Should -Be "93310000000300002"
    }
    It "RBC Credit Card maps to Credit Card Payments" {
        Get-AccountIdFromRules -Vendor "RBC Credit Card" | Should -Be "93310000000300002"
    }
}

Describe "Get-AccountIdFromRules vendor keyword rules for tax" -Tag "Bookkeeping", "Categorization" {
    It "PAD CCRA maps to Income Tax Expense" {
        Get-AccountIdFromRules -Vendor "PAD CCRA" | Should -Be "93310000000297002"
    }
}

Describe "Get-AccountIdFromRules entity vendor_account_map" -Tag "Bookkeeping", "Categorization" {
    It "Amazon.ca maps to Office and General Expenses" {
        Get-AccountIdFromRules -Vendor "Amazon.ca" | Should -Be "93310000000000400"
    }
    It "AliExpress maps to Other Expenses" {
        Get-AccountIdFromRules -Vendor "AliExpress" | Should -Be "93310000000000460"
    }
}

Describe "Get-AccountIdFromRules vendor_mappings fallback" -Tag "Bookkeeping", "Categorization" {
    It "Walmart Canada maps to Office and General Expenses" {
        Get-AccountIdFromRules -Vendor "Walmart Canada" | Should -Be "93310000000000400"
    }
    It "RONA maps to Repairs and Maintenance" {
        Get-AccountIdFromRules -Vendor "RONA" | Should -Be "93310000000000457"
    }
    It "Telus maps to Telephone" {
        Get-AccountIdFromRules -Vendor "Telus" | Should -Be "93310000000000421"
    }
    It "Rogers maps to Telephone" {
        Get-AccountIdFromRules -Vendor "Rogers" | Should -Be "93310000000000421"
    }
}

Describe "Get-AccountIdFromRules catch-all" -Tag "Bookkeeping", "Categorization" {
    It "Unknown vendor maps to Other Expenses" {
        $result = Get-AccountIdFromRules -Vendor "Random Unmatched Store" -PassThru
        $result.account_id | Should -Be "93310000000000460"
        $result.rule_source | Should -Be "catch-all"
    }
    It "PassThru returns account_name and rule_source" {
        $result = Get-AccountIdFromRules -Vendor "Unknown Vendor" -PassThru
        $result.account_name | Should -Be "Other Expenses"
        $result.rule_source | Should -Be "catch-all"
    }
}

Describe "Get-AccountIdFromRules Room Rentals entity" -Tag "Bookkeeping", "Categorization", "Regression-Only" {
    It "Petro-Canada room-rentals has 151803 prefix" {
        Get-AccountIdFromRules -Vendor "Petro-Canada" -EntitySlug "room-rentals" | Should -Be "151803000000000424"
    }
    It "Home Depot room-rentals has 151803 prefix" {
        Get-AccountIdFromRules -Vendor "Home Depot" -EntitySlug "room-rentals" | Should -Be "151803000000000457"
    }
    It "Zoho room-rentals has 151803 prefix" {
        Get-AccountIdFromRules -Vendor "Zoho Canada" -EntitySlug "room-rentals" | Should -Be "151803000000000427"
    }
    It "Unknown vendor room-rentals has 151803 Other Expenses" {
        Get-AccountIdFromRules -Vendor "Some Unknown Vendor" -EntitySlug "room-rentals" | Should -Be "151803000000000460"
    }
}

Describe "Get-AccountIdFromRules rule_source values" -Tag "Bookkeeping", "Categorization", "Regression-Only" {
    It "Zoho rule_source is vendor_keyword_rule" {
        $r = Get-AccountIdFromRules -Vendor "Zoho Canada" -PassThru
        $r.rule_source | Should -Be "vendor_keyword_rule"
    }
    It "WAVE SV9T rule_source is description_override" {
        $r = Get-AccountIdFromRules -Vendor "WAVE SV9T" -PassThru
        $r.rule_source | Should -Be "description_override"
    }
    It "Amazon.ca rule_source is vendor_account_map" {
        $r = Get-AccountIdFromRules -Vendor "Amazon.ca" -PassThru
        $r.rule_source | Should -Be "vendor_account_map"
    }
    It "Walmart rule_source is vendor_mapping" {
        $r = Get-AccountIdFromRules -Vendor "Walmart Canada" -PassThru
        $r.rule_source | Should -Be "vendor_mapping"
    }
    It "Unknown vendor rule_source is catch-all" {
        $r = Get-AccountIdFromRules -Vendor "Totally Unknown Store Inc" -PassThru
        $r.rule_source | Should -Be "catch-all"
    }
}

Describe "Get-IncomeClassification income patterns" -Tag "Bookkeeping", "Categorization" {
    It "WAVE SV9T classifies as Income" {
        $r = Get-IncomeClassification -Vendor "WAVE SV9T" -Amount 850.00
        $r.income_type | Should -Be "Income"
        $r.account_name | Should -Be "Consulting Revenue"
        $r.account_id | Should -Be "93310000000149102"
    }
    It "WAVE SV9T with client name classifies as Income" {
        $r = Get-IncomeClassification -Vendor "WAVE SV9T - CLIENT" -Amount 1234.56
        $r.income_type | Should -Be "Income"
        $r.rule_source | Should -Be "income_rules"
    }
    It "ONLINE BANKING TRANSFER to client classifies as Income" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "ABC Corp" -Amount 2750.50
        $r.income_type | Should -Be "Income"
        $r.account_name | Should -Be "Consulting Revenue"
    }
    It "ONLINE BANKING TRANSFER round amount to CC classifies as Transfer" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "VISA" -Amount 500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Credit Card Payments"
    }
    It "UPS HAVENS credit classifies as Income" {
        $r = Get-IncomeClassification -Vendor "UPS HAVENS" -Amount 500.00
        $r.income_type | Should -Be "Income"
        $r.account_name | Should -Be "Consulting Revenue"
    }
    It "E-Transfer AUTODEPOSIT with recipient name classifies as Income" {
        $r = Get-IncomeClassification -Vendor "E-TRANSFER AUTODEPOSIT" -Description "VICTOR SALMON" -Amount 2000.00
        $r.income_type | Should -Be "Income"
        $r.account_name | Should -Be "Consulting Revenue"
    }
    It "E-Transfer AUTODEPOSIT generic classifies as Transfer" {
        $r = Get-IncomeClassification -Vendor "E-TRANSFER AUTODEPOSIT" -Amount 500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Shareholder Loan"
    }
    It "INTEREST EARNED classifies as Income" {
        $r = Get-IncomeClassification -Vendor "INTEREST EARNED" -Amount 1.23
        $r.income_type | Should -Be "Income"
        $r.account_name | Should -Be "Interest Income"
    }
}

Describe "Get-IncomeClassification exclude patterns" -Tag "Bookkeeping", "Categorization" {
    It "TAX REFUND CANADA classifies as Income Tax Expense" {
        $r = Get-IncomeClassification -Vendor "TAX REFUND" -Description "CANADA" -Amount 1807.00
        $r.income_type | Should -Be "Exclude"
        $r.account_name | Should -Be "Income Tax Expense"
    }
    It "TAX REFUND (generic) classifies as Exclude" {
        $r = Get-IncomeClassification -Vendor "TAX REFUND" -Amount 1200.00
        $r.income_type | Should -Be "Exclude"
        $r.account_name | Should -Be "Exclude"
    }
    It "CASH BACK classifies as Exclude" {
        $r = Get-IncomeClassification -Vendor "CASH BACK" -Amount 50.00
        $r.income_type | Should -Be "Exclude"
    }
    It "ATM DEPOSIT classifies as Transfer (Shareholder Loan)" {
        $r = Get-IncomeClassification -Vendor "ATM DEPOSIT" -Amount 300.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Shareholder Loan"
    }
    It "PAD CCRA classifies as Exclude" {
        $r = Get-IncomeClassification -Vendor "PAD CCRA" -Amount 850.00
        $r.income_type | Should -Be "Exclude"
        $r.account_name | Should -Be "Income Tax Expense"
    }
}

Describe "Get-IncomeClassification expense and review" -Tag "Bookkeeping", "Categorization" {
    It "Refund on an expense classifies as Expense" {
        $r = Get-IncomeClassification -Vendor "PETRO-CANADA" -Amount 45.00
        $r.income_type | Should -Be "Expense"
        $r.account_name | Should -Be "Automobile Expense"
    }
    It "Unmatched credit classifies as Review" {
        $r = Get-IncomeClassification -Vendor "Unknown Payment Source" -Amount 150.00
        $r.income_type | Should -Be "Review"
        $r.rule_source | Should -Be "catch-all"
    }
}

Describe "Get-IncomeClassification transfer patterns" -Tag "Bookkeeping", "Categorization" {
    It "PAYMENT - THANK YOU classifies as Transfer" {
        $r = Get-IncomeClassification -Vendor "PAYMENT - THANK YOU" -Amount 1000.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Credit Card Payments"
    }
    It "AUTOMATIC PAYMENT classifies as Transfer" {
        $r = Get-IncomeClassification -Vendor "AUTOMATIC PAYMENT" -Amount 750.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Credit Card Payments"
    }
}

Describe "Get-IncomeClassification Round Amount detection" -Tag "Bookkeeping", "Categorization", "Regression-Only" {
    It "Round-amount OBT with CC keywords classifies as Transfer" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "CREDIT CARD" -Amount 500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Credit Card Payments"
    }
    It "Non-round OBT without CC keywords classifies as Income" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "Client Payment" -Amount 183.75
        $r.income_type | Should -Be "Income"
        $r.account_name | Should -Be "Consulting Revenue"
    }
    It "Large round OBT $2000 without CC keywords classifies as Shareholder Loan" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "" -Amount 2000.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Shareholder Loan"
    }
    It "Small round OBT $500 without CC keywords classifies as Credit Card Payment" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "" -Amount 500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Credit Card Payments"
    }
    It "OBT with owner name in description classifies as Shareholder Loan" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "VICTOR" -Amount 2000.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Shareholder Loan"
    }
    It "OBT with VAS in description classifies as Shareholder Loan" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "VAS" -Amount 1500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Shareholder Loan"
    }
    It "OBT with CC keywords and large amount still classifies as CC Payment" {
        $r = Get-IncomeClassification -Vendor "ONLINE BANKING TRANSFER" -Description "VISA" -Amount 2500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Credit Card Payments"
    }
    It "eTransfer with CC keywords in description classifies as SH Loan not CC Payment" {
        $r = Get-IncomeClassification -Vendor "E-TRANSFER AUTODEPOSIT" -Description "MASTERCARD payment" -Amount 500.00
        $r.income_type | Should -Be "Transfer"
        $r.account_name | Should -Be "Shareholder Loan"
    }
}
