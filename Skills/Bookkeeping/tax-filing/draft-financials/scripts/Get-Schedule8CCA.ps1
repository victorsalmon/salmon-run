<#
.SYNOPSIS
    Computes T2 Schedule 8 (Capital Cost Allowance) from opening UCC and additions.
.DESCRIPTION
    Given opening UCC, additions, and disposals per CCA class, computes CCA claim amounts
    using the declining-balance method with half-year rule for additions.
    The CCA rates and half-year rule flags come from the tax-year config.
.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER Classes
    Array of class definitions with opening_ucc, additions, disposals.
    Each entry must include a `class` number matching a key in Config.cca_classes.
.EXAMPLE
    $s8 = .\Get-Schedule8CCA.ps1 -Config $cfg -Classes @(
        @{ class = 8; opening_ucc = 15000; additions = 2000; disposals = 0 }
    )
#>
function Get-Schedule8CCA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [array]$Classes = @()
    )

    $totalCCA = 0.0
    if ($Classes.Count -eq 0) {
        $results = $Config.cca_classes | ForEach-Object {
            [PSCustomObject]@{
                class           = $_.class
                rate            = $_.rate
                rate_label      = if ($_.rate -eq 1.0) { "100%" } else { "$([math]::Round($_.rate * 100))%" }
                opening_ucc     = 0.0
                additions       = 0.0
                disposals       = 0.0
                ucc_before_cca  = 0.0
                half_year_adj   = 0.0
                cca_claimed     = 0.0
                closing_ucc     = 0.0
                note            = ""
            }
        }
        return [PSCustomObject]@{ classes = @($results); total_cca_claimed = 0.0 }
    }
    $results = foreach ($c in $Classes) {
        $classNum  = [int]$c.class
        $rate      = [double]$c.rate
        $opening   = [decimal]$c.opening_ucc
        $additions = [decimal]$c.additions
        $disposals = [decimal]$c.disposals

        $classDef = $Config.cca_classes | Where-Object { $_.class -eq $classNum } | Select-Object -First 1
        if (-not $classDef) {
            Write-Warning "CCA class $classNum not found in config - half-year rule defaults to off. Add class to tax-year-<year>.psd1 cca_classes if half-year should apply."
        }

        if ($classNum -eq 12) {
            [PSCustomObject]@{
                class           = $classNum
                rate            = $rate
                rate_label      = "100%"
                opening_ucc     = [math]::Round($opening, 2, [MidpointRounding]::AwayFromZero)
                additions       = [math]::Round($additions, 2, [MidpointRounding]::AwayFromZero)
                disposals       = [math]::Round($disposals, 2, [MidpointRounding]::AwayFromZero)
                ucc_before_cca  = 0.0
                half_year_adj   = 0.0
                cca_claimed     = [math]::Round($additions, 2, [MidpointRounding]::AwayFromZero)
                closing_ucc     = 0.0
                note            = "100% immediate expensing"
                pctLabel        = "100%"
            }
            $totalCCA += [decimal]$additions
            continue
        }

        $halfYearRule = if ($classDef) { $classDef.half_year } else { $true }
        $halfYearAdditions = if ($halfYearRule) { $additions * 0.5 } else { $additions }
        $decliningBalance = ($opening - $disposals) + $halfYearAdditions
        if ($decliningBalance -lt 0) { $decliningBalance = 0 }
        $ccaClaimed = $decliningBalance * $rate

        $pctLabel = if ($rate -eq 1.0) { "100%" } else { "$([math]::Round($rate * 100))%" }

        [PSCustomObject]@{
            class           = $classNum
            rate            = $rate
            rate_label      = $pctLabel
            opening_ucc     = [math]::Round($opening, 2, [MidpointRounding]::AwayFromZero)
            additions       = [math]::Round($additions, 2, [MidpointRounding]::AwayFromZero)
            disposals       = [math]::Round($disposals, 2, [MidpointRounding]::AwayFromZero)
            ucc_before_cca = [math]::Round($decliningBalance, 2, [MidpointRounding]::AwayFromZero)
            half_year_adj  = [math]::Round($halfYearAdditions, 2, [MidpointRounding]::AwayFromZero)
            cca_claimed    = [math]::Round($ccaClaimed, 2, [MidpointRounding]::AwayFromZero)
            closing_ucc    = [math]::Round(($decliningBalance - $ccaClaimed), 2, [MidpointRounding]::AwayFromZero)
            note           = if ($halfYearAdditions -gt 0) { 'Half-year rule applied' } else { '' }
        }
        $totalCCA += $ccaClaimed
    }

    return [PSCustomObject]@{
        classes           = @($results)
        total_cca_claimed = [math]::Round([decimal]$totalCCA, 2, [MidpointRounding]::AwayFromZero)
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-Schedule8CCA') {
    $cfg = if (Get-Command Get-DraftT2Config -ErrorAction SilentlyContinue) { Get-DraftT2Config }
    if (-not $cfg) { . (Join-Path $PSScriptRoot 'Get-DraftT2Config.ps1'); $cfg = Get-DraftT2Config }
    $demoClasses = @(
        @{ class = 8;  rate = 0.20; opening_ucc = 15000; additions = 2000; disposals = 0 }
        @{ class = 10; rate = 0.30; opening_ucc = 8000;  additions = 0;    disposals = 1500 }
        @{ class = 50; rate = 0.55; opening_ucc = 3000;  additions = 0;    disposals = 0 }
        @{ class = 12; rate = 1.00; opening_ucc = 0;     additions = 500;  disposals = 0 }
    )
    Get-Schedule8CCA -Config $cfg -Classes $demoClasses
}

