<#
    # Used by: Skills/Bookkeeping/tax-filing/draft-financials/skills/draft-t2-filing.md
.SYNOPSIS
    Computes T2 Schedule 4 — Small Business Deduction and tax payable estimate.
.DESCRIPTION
    Takes net income for tax purposes and Aggregate Investment Income (AII),
    computes Active Business Income (ABI), applies the SBD rate reduction
    (federal 19% + BC 10%), and produces a tax payable estimate.

    Rates come from the Config object loaded by Get-DraftT2Config from the
    year-specific PSD1 file (e.g. tax-year-2026.psd1).
.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER NetIncomeForTax
    Net income for tax purposes from Schedule 1 (after adjustments + CCA).
.PARAMETER InterestIncome
    Interest income amount (primary component of AII for Intersite Consulting).
.PARAMETER TaxableCapitalGains
    Taxable capital gains for the year (default 0).
.PARAMETER PropertyIncome
    Property income for the year (default 0).
.PARAMETER InstalmentsPaid
    Total tax instalments paid during the year (for refund/balance-owing calc).
.EXAMPLE
    $s4 = .\Get-Schedule4SBD.ps1 -Config $cfg -NetIncomeForTax 65000 -InterestIncome 1200 -InstalmentsPaid 4000
#>
function Get-Schedule4SBD {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [Parameter(Mandatory)]
        [decimal]$NetIncomeForTax,

        [decimal]$InterestIncome = 0,

        [decimal]$TaxableCapitalGains = 0,

        [decimal]$PropertyIncome = 0,

        [decimal]$InstalmentsPaid = 0
    )

    $rates    = $Config.tax_rates
    $bcRates  = $Config.bc_tax_rates
    $limits   = $Config.business_limits

    # --- Aggregate Investment Income ---
    $aii = $InterestIncome + $TaxableCapitalGains + $PropertyIncome

    # --- Active Business Income ---
    $abi = $NetIncomeForTax - $aii
    if ($abi -lt 0) { $abi = 0 }

    # --- Business limit reduction if AII > threshold ---
    $threshold = [decimal]$Config.aii_threshold
    $businessLimitFederal = [decimal]$limits.federal
    $businessLimitBC      = [decimal]$limits.bc

    if ($aii -gt $threshold) {
        $excessAII = $aii - $threshold
        $reduction = [Math]::Ceiling($excessAII / 10000) * 5000
        $businessLimitFederal = [Math]::Max([decimal]0, $businessLimitFederal - $reduction)
        $businessLimitBC      = [Math]::Max([decimal]0, $businessLimitBC - $reduction)
    }

    $abiForSBD_Fed = [Math]::Min($abi, $businessLimitFederal)
    $abiForSBD_BC  = [Math]::Min($abi, $businessLimitBC)

    # Federal SBD: income × federal_small_business_deduction_rate (0.19)
    # BC SBD reduction: bc_general_rate (0.12) − bc_small_business_rate (0.02) = 0.10
    $sbdFederalReduction  = $abiForSBD_Fed * [decimal]$rates.federal_small_business_deduction_rate
    $bcSbdReductionRate   = [decimal]$bcRates.bc_general_rate - [decimal]$bcRates.bc_small_business_rate
    $sbdProvincialReduction = $abiForSBD_BC * $bcSbdReductionRate

    # --- Tax Payable Estimate ---
    $partITaxBeforeSbd = $NetIncomeForTax * [decimal]$rates.federal_part_i_rate_before_sbd
    $partITaxAfterSbd  = $partITaxBeforeSbd - $sbdFederalReduction

    $bcTaxBeforeSbd    = $NetIncomeForTax * [decimal]$bcRates.bc_general_rate
    $bcTaxAfterSbd     = $bcTaxBeforeSbd - $sbdProvincialReduction

    $totalTax = [Math]::Max([decimal]0, [math]::Round($partITaxAfterSbd + $bcTaxAfterSbd, 2, [MidpointRounding]::AwayFromZero))
    $refund   = $InstalmentsPaid - $totalTax

    return [PSCustomObject]@{
        active_business_income            = [math]::Round($abi, 2, [MidpointRounding]::AwayFromZero)
        aggregate_investment_income       = [math]::Round($aii, 2, [MidpointRounding]::AwayFromZero)
        interest_income                   = [math]::Round($InterestIncome, 2, [MidpointRounding]::AwayFromZero)
        taxable_capital_gains             = [math]::Round($TaxableCapitalGains, 2, [MidpointRounding]::AwayFromZero)

        business_limit_federal            = [math]::Round($businessLimitFederal, 2, [MidpointRounding]::AwayFromZero)
        business_limit_bc                 = [math]::Round($businessLimitBC, 2, [MidpointRounding]::AwayFromZero)
        business_limit_used_federal       = [math]::Round($abiForSBD_Fed, 2, [MidpointRounding]::AwayFromZero)
        business_limit_used_bc            = [math]::Round($abiForSBD_BC, 2, [MidpointRounding]::AwayFromZero)

        sbd_federal_reduction             = [math]::Round($sbdFederalReduction, 2, [MidpointRounding]::AwayFromZero)
        sbd_provincial_reduction          = [math]::Round($sbdProvincialReduction, 2, [MidpointRounding]::AwayFromZero)

        tax_estimate = [PSCustomObject]@{
            federal_part_i_rate_before_sbd = [decimal]$rates.federal_part_i_rate_before_sbd
            bc_general_rate                = [decimal]$bcRates.bc_general_rate
            part_i_tax_before_sbd          = [math]::Round($partITaxBeforeSbd, 2, [MidpointRounding]::AwayFromZero)
            sbd_reduction_federal          = [math]::Round($sbdFederalReduction, 2, [MidpointRounding]::AwayFromZero)
            part_i_tax_after_sbd           = [math]::Round($partITaxAfterSbd, 2, [MidpointRounding]::AwayFromZero)
            bc_tax_before_sbd              = [math]::Round($bcTaxBeforeSbd, 2, [MidpointRounding]::AwayFromZero)
            sbd_reduction_bc               = [math]::Round($sbdProvincialReduction, 2, [MidpointRounding]::AwayFromZero)
            bc_tax_after_sbd               = [math]::Round($bcTaxAfterSbd, 2, [MidpointRounding]::AwayFromZero)
            total_tax_payable              = [math]::Round($totalTax, 2, [MidpointRounding]::AwayFromZero)
            instalments_paid               = [math]::Round($InstalmentsPaid, 2, [MidpointRounding]::AwayFromZero)
            estimated_refund_balance_owing = [math]::Round($refund, 2, [MidpointRounding]::AwayFromZero)
        }
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-Schedule4SBD') {
    if (-not (Get-Command Get-DraftT2Config -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "Get-DraftT2Config.ps1") }
    $cfg = Get-DraftT2Config
    Get-Schedule4SBD -Config $cfg -NetIncomeForTax 65000 -InterestIncome 1200 -InstalmentsPaid 4000
}

