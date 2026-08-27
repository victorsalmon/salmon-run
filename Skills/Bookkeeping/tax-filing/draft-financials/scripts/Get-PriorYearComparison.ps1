<#
.SYNOPSIS
    Cross-references current year draft figures against prior year NOA data.
.DESCRIPTION
    Extracts prior year figures from a structured sidecar (NOA extraction CSV) and
    compares them against current year draft values. Flags variances exceeding
    the threshold defined in Config (default 50%) for user review.
.PARAMETER Config
    Draft T2 config object from Get-DraftT2Config.
.PARAMETER CurrentYear
    Hashtable of current year draft values with keys: revenue, net_income,
    taxable_income, sbd_claimed, cca_claimed, dividends_paid, tax_payable.
.PARAMETER PriorYearNOACsv
    Path to prior year NOA extraction sidecar CSV (columns: metric, amount).
.PARAMETER PriorYearValues
    Alternative to CSV — hashtable with same keys as CurrentYear.
.PARAMETER VarianceThreshold
    Variance threshold for flagging (decimal, default 0.50 = 50%).
.EXAMPLE
    $comp = .\Get-PriorYearComparison.ps1 -Config $cfg -CurrentYear $cy -PriorYearValues $py
#>
function Get-PriorYearComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Config,

        [Parameter(Mandatory)]
        [hashtable]$CurrentYear,

        [string]$PriorYearNOACsv,

        [hashtable]$PriorYearValues,

        [double]$VarianceThreshold = $Config.variance_flag_threshold
    )

    $py = if ($PriorYearNOACsv) {
        if (-not (Test-Path $PriorYearNOACsv)) { throw "Prior year NOA CSV not found: $PriorYearNOACsv" }
        $ht = @{}
        Import-Csv $PriorYearNOACsv | ForEach-Object { $ht[$_.metric] = [decimal]$_.amount }
        $ht
    } elseif ($PriorYearValues) {
        $PriorYearValues
    } else {
        @{}
    }

    $metrics = @("revenue", "net_income", "taxable_income", "sbd_claimed", "cca_claimed", "dividends_paid", "tax_payable")
    $comparisons = @{}
    $flags = @()

    foreach ($m in $metrics) {
        $cyVal = if ($CurrentYear.ContainsKey($m)) { [double]$CurrentYear[$m] } else { 0.0 }
        $pyVal = if ($py.ContainsKey($m)) { [double]$py[$m] } else { 0.0 }

        $variance = $cyVal - $pyVal
        $variancePct = if ($pyVal -ne 0) { [Math]::Abs($variance / $pyVal) } else { if ($cyVal -ne 0) { 1.0 } else { 0.0 } }

        $comparisons[$m] = [PSCustomObject]@{
            prior_year    = [math]::Round($pyVal, 2, [MidpointRounding]::AwayFromZero)
            current_year  = [math]::Round($cyVal, 2, [MidpointRounding]::AwayFromZero)
            variance      = [math]::Round($variance, 2, [MidpointRounding]::AwayFromZero)
            variance_pct  = [math]::Round($variancePct, 4, [MidpointRounding]::AwayFromZero)
        }

        if ($variancePct -gt $VarianceThreshold) {
            $direction = if ($variance -gt 0) { "increase" } else { "decrease" }
            $flags += "${m}: $([math]::Round($variancePct * 100, 0, [MidpointRounding]::AwayFromZero))% $direction from prior year (threshold: $([math]::Round($VarianceThreshold * 100, 0, [MidpointRounding]::AwayFromZero))%)"
        }
    }

    return [PSCustomObject]@{
        comparisons = [PSCustomObject]$comparisons
        variance_flags = $flags
        threshold      = $VarianceThreshold
        has_flags      = $flags.Count -gt 0
    }
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-PriorYearComparison') {
    if (-not (Get-Command Get-DraftT2Config -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "Get-DraftT2Config.ps1") }
    $cfg = Get-DraftT2Config
    $cy = @{ revenue = 85000; net_income = 45000; taxable_income = 42000; sbd_claimed = 30000; cca_claimed = 5000; dividends_paid = 15000; tax_payable = 4000 }
    $py = @{ revenue = 72000; net_income = 38000; taxable_income = 35000; sbd_claimed = 25000; cca_claimed = 4500; dividends_paid = 12000; tax_payable = 3500 }
    Get-PriorYearComparison -Config $cfg -CurrentYear $cy -PriorYearValues $py
}

