<#
.SYNOPSIS
    Computes GST/HST reconciliation for T2 filing reference.
.DESCRIPTION
    Takes consulting revenue and expense data categorized by vendor,
    calculates GST collected (revenue × 5%) and ITCs (from GST-applicable expenses),
    and returns a structured GST reconciliation for T2 reference.
.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER ConsultingRevenue
    Total consulting revenue for the fiscal year.
.PARAMETER ExpensesByVendor
    Hashtable keyed by vendor name with total expense amounts.
    Vendor names are matched against gst_vendor_categories patterns in Config.
.PARAMETER ExpensesCSV
    Alternative to ExpensesByVendor — CSV with columns: vendor, amount.
.PARAMETER GSTPayableFromTB
    GST/HST Payable balance from Zoho Trial Balance (optional, for cross-reference).
.EXAMPLE
    $gst = .\Get-GSTReconciliation.ps1 -Config $cfg -ConsultingRevenue 85000 -ExpensesByVendor $vendorExpenses
.EXAMPLE
    $gst = .\Get-GSTReconciliation.ps1 -Config $cfg -ConsultingRevenue 85000 -ExpensesCSV "C:\data\expenses.csv"
#>
function Get-GSTReconciliation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [Parameter(Mandatory)]
        [decimal]$ConsultingRevenue,

        [hashtable]$ExpensesByVendor,

        [string]$ExpensesCSV,

        [decimal]$GSTPayableFromTB = 0
    )

    $gstRate = [decimal]$Config.gst.rate
    $reverseFactor = [decimal]$Config.gst.reverse_factor
    $vendorCats = $Config.gst_vendor_categories

    # --- Load expense data ---
    $vendorExpenses = if ($ExpensesCSV) {
        if (-not (Test-Path $ExpensesCSV)) { throw "Expenses CSV not found: $ExpensesCSV" }
        $ht = @{}
        Import-Csv $ExpensesCSV | ForEach-Object {
            $v = $_.vendor; $a = [decimal]$_.amount
            if ($ht.ContainsKey($v)) { $ht[$v] += $a } else { $ht[$v] = $a }
        }
        $ht
    } elseif ($ExpensesByVendor) {
        $ExpensesByVendor
    } else {
        @{}
    }

    # --- Categorize expenses and compute ITCs ---
    $categorized = @{}
    $itcTotal = 0.0
    $gstApplicableTotal = 0.0

    foreach ($vendor in $vendorExpenses.Keys) {
        $amount = [decimal]$vendorExpenses[$vendor]
        $matched = $false

        foreach ($cat in $vendorCats) {
            if ($vendor -match $cat.pattern) {
                $factor = [decimal]$cat.factor
                if (-not $categorized.ContainsKey($cat.category)) {
                    $categorized[$cat.category] = 0.0
                }
                $categorized[$cat.category] += [double]$amount

                if ($factor -gt 0) {
                    $itc = [math]::Round($amount * $factor, 2, [MidpointRounding]::AwayFromZero)
                    $itcTotal += $itc
                    $gstApplicableTotal += $amount
                }
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            $uncategorized = "Uncategorized"
            if (-not $categorized.ContainsKey($uncategorized)) {
                $categorized[$uncategorized] = 0.0
            }
            $categorized[$uncategorized] += [double]$amount
        }
    }

    $totalExpensesAnalyzed = ($vendorExpenses.Values | Measure-Object -Sum).Sum
    if ($totalExpensesAnalyzed -gt 0 -and $itcTotal -eq 0) {
        Write-Warning "Expenses total `$$([math]::Round($totalExpensesAnalyzed, 2, [MidpointRounding]::AwayFromZero)) but no ITCs computed. All vendors matched zero-GST categories (US Digital, Bank Fees, CRA) or were uncategorized. Verify vendor names match gst_vendor_categories patterns in tax-year-*.psd1."
    }

    $gstCollected = [math]::Round($ConsultingRevenue * $gstRate, 2, [MidpointRounding]::AwayFromZero)
    $netGST = $gstCollected - [math]::Round($itcTotal, 2, [MidpointRounding]::AwayFromZero)

    return [PSCustomObject]@{
        gst_collected             = $gstCollected
        itcs_claimed              = [math]::Round($itcTotal, 2, [MidpointRounding]::AwayFromZero)
        net_gst_remittable        = [math]::Round($netGST, 2, [MidpointRounding]::AwayFromZero)
        gst_payable_balance_sheet = [math]::Round($GSTPayableFromTB, 2, [MidpointRounding]::AwayFromZero)

        gst_on_income = [PSCustomObject]@{
            consulting_revenue = [math]::Round($ConsultingRevenue, 2, [MidpointRounding]::AwayFromZero)
            gst_rate           = $gstRate
            gst_collected      = $gstCollected
        }

        expenses_summary = [PSCustomObject]@{
            total_expenses_analyzed = [math]::Round([decimal]($vendorExpenses.Values | Measure-Object -Sum).Sum, 2, [MidpointRounding]::AwayFromZero)
            gst_applicable_total    = [math]::Round($gstApplicableTotal, 2, [MidpointRounding]::AwayFromZero)
            reverse_factor          = $reverseFactor
            categorized = [PSCustomObject]$categorized
        }
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-GSTReconciliation') {
    if (-not (Get-Command Get-DraftT2Config -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "Get-DraftT2Config.ps1") }
    $cfg = Get-DraftT2Config
    $demoExpenses = @{
        "Zoho Canada"      = 2400
        "Petro-Canada"     = 3200
        "ICBC"             = 1800
        "AuroMaitreyi"     = 12000
        "OpenRouter Inc"   = 600
        "RBC Royal Bank"   = 300
        "Amazon.ca"        = 900
        "Staples"          = 200
    }
    Get-GSTReconciliation -Config $cfg -ConsultingRevenue 85000 -ExpensesByVendor $demoExpenses
}

