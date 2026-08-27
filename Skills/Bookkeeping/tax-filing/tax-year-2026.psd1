@{
    # ============================================================================
    # T2 Tax Year Data — Fiscal Year 2026 (ending 2026-03-31)
    # ============================================================================
    # Single source of truth for all government rates, limits, and year-dependent
    # variables used in T2 draft filing. Copy this file to create a new tax year:
    #   cp tax-year-2026.psd1 tax-year-2027.psd1
    # Then update only the values that changed.
    #
    # All rates are decimals (e.g., 28% = 0.28).
    # "Rate" = a rate of tax applied to income.
    # "Reduction" = a rate that reduces tax otherwise payable.
    # "Before SBD" = before the small business deduction is subtracted.
    #
    # Loaded by: Get-DraftT2Config (Skills/Bookkeeping/tax-filing/draft-financials/scripts/Get-DraftT2Config.ps1)
    # Referenced by: Skills/Bookkeeping/tax-filing/draft-financials/skills/draft-t2-filing.md
    # Also used by:  Skills/Bookkeeping/tax-filing/draft-financials/skills/draft-gst-filing.md
    # ============================================================================

    fiscal_year_end = "2026-03-31"
    entity          = "Intersite Consulting Inc."

    # --- Federal Corporate Tax Rates (2026) ---
    # Part I: 38% basic rate − 10% provincial abatement = 28% before SBD
    # Small business deduction: reduces Part I by 19pp (CCPCs claiming SBD cannot
    #   also claim the general rate reduction).
    # Net federal rate with SBD = 28% − 19% = 9%
    tax_rates = @{
        federal_part_i_rate_before_sbd          = 0.28
        federal_small_business_deduction_rate   = 0.19
    }

    # --- BC Corporate Tax Rates (2026) ---
    # BC general rate: 12%
    # BC small business rate (paid on ABI up to limit): 2%
    # BC SBD reduction = bc_general_rate − bc_small_business_rate = 10%
    bc_tax_rates = @{
        bc_general_rate        = 0.12
        bc_small_business_rate = 0.02
    }

    # --- Business Limits ---
    business_limits = @{
        federal = 500000
        bc      = 500000
    }

    # --- GST/HST ---
    gst = @{
        rate           = 0.05
        reverse_factor = 0.04761904761904762
    }

    # --- AII Threshold ---
    aii_threshold = 50000

    # --- GIFI Account-to-T2 Line Mapping ---
    # Corrected per prior year (2025) filed T2 Schedule 125 extraction.
    # Source: intersite-docs/.../2025 (Reinvest Wealth)/2025 - T2 - extraction (fitz).md
    # Key corrections from 2025 filing:
    #   Professional Fees 8810→8860, Office 8760→8810, Bank Fees 8550→8710,
    #   IT 8710→8810, Repairs 8830→8960, Telephone 8860→9220, Interest Income 8300→8231
    gifi = @{
        income = @(
            @{ account = "Consulting Revenue"; gifi = 8299; label = "Gross Revenue";          type = "revenue"     }
            @{ account = "Interest Income";    gifi = 8231; label = "Other Income";            type = "other_income" }
        )
        expenses = @(
            @{ account = "Advertising";                        gifi = 8520; label = "Advertising"            }
            @{ account = "Donations|8522";                    gifi = 8522; label = "Donations"              }
            @{ account = "Automobile|Motor vehicle|Vehicle|9281"; gifi = 9281; label = "Vehicle"               }
            @{ account = "Bank Fees|Bank Fees and Charges|Credit Card Charges"; gifi = 8710; label = "Interest & Bank Charges"  }
            @{ account = "^(?!.*Vehicle)Insurance";            gifi = 8620; label = "Insurance"              }
            @{ account = "IT.*Internet|Software.*IT";            gifi = 8810; label = "IT & Internet"          }
            @{ account = "Tech.*repair|Computer.*accessor|Peripheral"; gifi = 9150; label = "Tech repair, support, subscriptions, peripherals" }
            @{ account = "Computer Upgrade|9151";              gifi = 9151; label = "Computer upgrades under 500" }
            @{ account = "Lease|Rent Expense";                 gifi = 8720; label = "Lease"                  }
            @{ account = "Office.*General|Office Expenses";     gifi = 8810; label = "Office & General"       }
            @{ account = "Professional Fees";                  gifi = 8860; label = "Professional Fees"      }
            @{ account = "8960.*Repairs";                    gifi = 8960; label = "Repairs & Maintenance" }
            @{ account = "Telephone";                          gifi = 9220; label = "Telephone"              }
            @{ account = "Travel";                             gifi = 8880; label = "Travel"                 }
            @{ account = "Other Expenses";                     gifi = 9275; label = "Other Expenses"         }
         )
    }

    # --- CCA Classes ---
    # Opening UCC per FY2025 filed T2 Schedule 8 extraction.
    # Source: intersite-docs/.../2025 (Reinvest Wealth)/2025 - T2 - extraction (fitz).md
    #   Class 50: Prior year CCA $816 ÷ 0.55 = $1,483.64 → opening $668 (rounded for CloudTax entry)
    #   Class  8: Prior year CCA $21  ÷ 0.20 = $105.00  → opening $84.00
    # FY2026 closing UCC (carries to FY2027 as opening UCC):
    #   Class 50: $300.60  (computer hardware, 55%)
    #   Class  8: $67.20   (furniture/tools $500+, 20%)
    cca_classes = @(
        @{ class = 8;  rate = 0.20; name = "Class 8 (20%)";   half_year = $true;  opening_ucc = 84.00; additions = 0; disposals = 0 }
        @{ class = 10; rate = 0.30; name = "Class 10 (30%)";  half_year = $true;  opening_ucc = 0;     additions = 0; disposals = 0 }
        @{ class = 50; rate = 0.55; name = "Class 50 (55%)";  half_year = $true;  opening_ucc = 668.00; additions = 0; disposals = 0 }
        @{ class = 12; rate = 1.00; name = "Class 12 (100%)"; half_year = $false; opening_ucc = 0;     additions = 0; disposals = 0 }
    )

    # --- GST Vendor Categories (ITC matching) ---
    gst_vendor_categories = @(
        @{ category = "Canadian Software";  pattern = "Zoho|Kilo Code|FreshBooks|Wave|ReInvestWealth";   factor = 0.04761904761904762 }
        @{ category = "Canadian Fuel";      pattern = "Petro-Can|Shell|Chevron|Esso";                   factor = 0.04761904761904762 }
        @{ category = "Canadian Insurance"; pattern = "ICBC|Canada Life|Sun Life";                      factor = 0.04761904761904762 }
        @{ category = "Canadian Lease";     pattern = "AuroMaitreyi|Property Manager";                   factor = 0.04761904761904762 }
        @{ category = "Canadian Telecom";   pattern = "Freedom Mobile|Telus|Rogers|Bell|Shaw|Fido|Koodo"; factor = 0.04761904761904762 }
        @{ category = "US Digital";         pattern = "OpenRouter|Stripe|AWS|DigitalOcean|Moz|Google|Microsoft|GitHub|InterServer|WPForms|BoldSign|AppSumo"; factor = 0 }
        @{ category = "Bank Fees";          pattern = "RBC|TD|BMO|CIBC|Scotia";                         factor = 0                  }
        @{ category = "CRA Payments";       pattern = "CRA|CCRA|Canada Revenue";                        factor = 0                  }
        @{ category = "Amazon Canada";      pattern = "Amazon|AMZ";                                     factor = 0.04761904761904762 }
        @{ category = "Canadian Office";    pattern = "Staples|Grand & Toy|Best Buy|Home Depot|Dollarama|London Drugs"; factor = 0.04761904761904762 }
    )

    # --- Personal Use Percentages ---
    # Percentage of each expense category that is personal (non-deductible).
    # Applied as a Schedule 1 add-back adjustment.
    personal_use_percentages = @{
        Vehicle = 0.50    # 50% personal driving use (matches GIFI label "Vehicle")
    }

    # --- Variance Flag Threshold ---
    variance_flag_threshold = 0.50

    # ============================================================================
    # Prior Year (2025) Data — extracted from 2025 T2 filing
    #   Source: intersite-docs/.../2019-2025 Filings/T2 Corporate Tax Returns/
    #           2025 (Reinvest Wealth)/2025 - T2 - extraction (fitz).md
    #   Filed by: Reinvest Wealth (CPA)
    #   FY ending: 2025-03-31
    # ============================================================================
    prior_year = @{
        fiscal_year_end = "2025-03-31"
        revenue         = 22331.00
        net_income      = 15934.00
        taxable_income  = 15934.00
        sbd_claimed     = 3027.00
        cca_claimed     = 837.00
        dividends_paid  = 13307.00
        tax_payable     = 1754.00
        instalments     = 3561.00
        refund          = 1807.00
    }
}
