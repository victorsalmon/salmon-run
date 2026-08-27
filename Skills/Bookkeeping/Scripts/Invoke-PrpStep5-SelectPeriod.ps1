<#
.SYNOPSIS
    PRP Step 5: Select reconciliation scope (fiscal period/year).
.DESCRIPTION
    Determines which periods to reconcile: user-specified > last complete
    fiscal year > most recent partial/unreconciled fiscal year. Only periods
    backed by discovered PDFs (Step 4) are eligible.
.PARAMETER DiscoveredPeriods
    Array of period objects from Step 4 (PDF statement discovery).
.PARAMETER OrgName
    Organization name.
.PARAMETER AccountName
    Account slug name.
.PARAMETER FiscalYear
    Optional user-specified fiscal year label (e.g. "2026" for FY ending 2026).
.PARAMETER PeriodEnd
    Optional user-specified single period end date (e.g. "2026-03-31").
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER Headers
    HTTP headers for API calls.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER WhatIf
    Dry-run: log what would happen, don't execute.
.EXAMPLE
    Invoke-PrpStep5-SelectPeriod.ps1 -DiscoveredPeriods $periods -OrgName "intersite-consulting"
.EXAMPLE
    Invoke-PrpStep5-SelectPeriod.ps1 -DiscoveredPeriods $periods -OrgName "intersite-consulting" -FiscalYear "2026"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [array]$DiscoveredPeriods,

    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter()]
    [string]$AccountName,

    [Parameter()]
    [string]$FiscalYear,

    [Parameter()]
    [string]$PeriodEnd,

    [Parameter()]
    [string]$Token,

    [Parameter()]
    [hashtable]$Headers,

    [Parameter()]
    [string]$OrgId,

    [Parameter()]
    [string]$AccountId
)

$ErrorActionPreference = "Stop"
$stepNumber = 5
$stepName = "Period / Fiscal Year Selection"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 5] WhatIf: would select scope from $($DiscoveredPeriods.Count) discovered periods" -Tags PRP
    Write-Information "[PRP STEP 5] WhatIf: User params — FiscalYear=$FiscalYear PeriodEnd=$PeriodEnd" -Tags PRP
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $true
        Details        = "WhatIf: period selection skipped"
        SelectedScope  = $null
    }
}

# Determine fiscal year config per org — default to calendar year
$fiscalYearStartMonth = 1
$fiscalYearStartDay = 1
if ($OrgName -match "intersite") {
    $fiscalYearStartMonth = 4
    $fiscalYearStartDay = 1
}

function Get-FiscalYearLabel {
    param([datetime]$Date, [int]$StartMonth, [int]$StartDay)
    $year = $Date.Year
    if ($Date.Month -lt $StartMonth -or ($Date.Month -eq $StartMonth -and $Date.Day -lt $StartDay)) {
        $year
    } else {
        $year + 1
    }
}

function Get-FiscalYearRange {
    param([int]$FyLabel, [int]$StartMonth, [int]$StartDay)
    $start = [datetime]::new($FyLabel - 1, $StartMonth, $StartDay)
    $end = [datetime]::new($FyLabel, $StartMonth, $StartDay).AddDays(-1)
    return @{ Start = $start; End = $end }
}

# Parse discovered periods into datetime objects
$parsedPeriods = $DiscoveredPeriods | ForEach-Object {
    $end = if ($_.period_end -is [datetime]) { $_.period_end } else {
        $parsed = $null; [datetime]::TryParse($_.period_end, [ref]$parsed) | Out-Null; $parsed
    }
    $closing = if ($_.closing_balance) { [decimal]$_.closing_balance } else { 0 }
    if ($end) {
        [PSCustomObject]@{
            period_end      = $end
            closing_balance = $closing
            source_file     = $_.source_file
        }
    }
} | Where-Object { $_ }

$parsedPeriods = $parsedPeriods | Sort-Object period_end

if ($parsedPeriods.Count -eq 0) {
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $false
        Details       = "No valid discovered periods after parsing"
        SelectedScope = $null
        NextSteps     = @("Run Step 4 (Discover PDF Statements) first")
    }
}

$selectedScope = $null
$today = Get-Date

# Rule 1: User-specified -PeriodEnd
if ($PeriodEnd) {
    $targetDate = $null; [datetime]::TryParse($PeriodEnd, [ref]$targetDate) | Out-Null
    if ($targetDate) {
        $matching = $parsedPeriods | Where-Object { $_.period_end.Date -eq $targetDate.Date }
        if ($matching.Count -gt 0) {
            $fyLabel = Get-FiscalYearLabel -Date $targetDate -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay
            $selectedScope = [PSCustomObject]@{
                fiscal_year_label = "$fyLabel"
                fiscal_year_start = (Get-FiscalYearRange -FyLabel $fyLabel -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay).Start.ToString('yyyy-MM-dd')
                fiscal_year_end   = (Get-FiscalYearRange -FyLabel $fyLabel -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay).End.ToString('yyyy-MM-dd')
                mode              = "user-specified-period"
                periods           = @($matching)
            }
            Write-Information "[PRP STEP 5] User-specified period: $PeriodEnd — matched to FY$fyLabel" -Tags PRP
        }
    }
}

# Rule 2: User-specified -FiscalYear
if (-not $selectedScope -and $FiscalYear) {
    $fyNum = 0; [int]::TryParse($FiscalYear, [ref]$fyNum) | Out-Null
    if ($fyNum -gt 0) {
        $fy = Get-FiscalYearRange -FyLabel $fyNum -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay
        $inRange = $parsedPeriods | Where-Object { $_.period_end -ge $fy.Start -and $_.period_end -le $fy.End }
        if ($inRange.Count -gt 0) {
            $selectedScope = [PSCustomObject]@{
                fiscal_year_label = "$fyNum"
                fiscal_year_start = $fy.Start.ToString('yyyy-MM-dd')
                fiscal_year_end   = $fy.End.ToString('yyyy-MM-dd')
                mode              = "user-specified-fy"
                periods           = @($inRange)
            }
            Write-Information "[PRP STEP 5] User-specified fiscal year: $fyNum — $($inRange.Count) period(s)" -Tags PRP
        }
    }
}

# Rule 3: Last complete fiscal year
if (-not $selectedScope) {
    $fyCandidates = $parsedPeriods | ForEach-Object {
        $lbl = Get-FiscalYearLabel -Date $_.period_end -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay
        [PSCustomObject]@{ Label = $lbl; Period = $_ }
    } | Group-Object Label | ForEach-Object {
        $fy = Get-FiscalYearRange -FyLabel ([int]$_.Name) -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay
        [PSCustomObject]@{
            Label       = $_.Name
            Start       = $fy.Start
            End         = $fy.End
            PeriodCount = $_.Group.Count
            Periods     = @($_.Group.Period)
        }
    } | Where-Object { $_.End -lt $today } | Sort-Object End -Descending

    $firstComplete = $fyCandidates | Select-Object -First 1
    if ($firstComplete) {
        $selectedScope = [PSCustomObject]@{
            fiscal_year_label = $firstComplete.Label
            fiscal_year_start = $firstComplete.Start.ToString('yyyy-MM-dd')
            fiscal_year_end   = $firstComplete.End.ToString('yyyy-MM-dd')
            mode              = "last-complete-fy"
            periods           = @($firstComplete.Periods)
        }
        Write-Information "[PRP STEP 5] Last complete fiscal year: $($firstComplete.Label) — $($firstComplete.PeriodCount) period(s)" -Tags PRP
    }
}

# Rule 4: Most recent partial (current) fiscal year
if (-not $selectedScope) {
    $currentFyLabel = Get-FiscalYearLabel -Date $today -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay
    $currentFy = Get-FiscalYearRange -FyLabel $currentFyLabel -StartMonth $fiscalYearStartMonth -StartDay $fiscalYearStartDay
    $inCurrent = $parsedPeriods | Where-Object { $_.period_end -ge $currentFy.Start -and $_.period_end -le $today }

    if ($inCurrent.Count -gt 0) {
        $selectedScope = [PSCustomObject]@{
            fiscal_year_label = "$currentFyLabel"
            fiscal_year_start = $currentFy.Start.ToString('yyyy-MM-dd')
            fiscal_year_end   = $currentFy.End.ToString('yyyy-MM-dd')
            mode              = "partial-fy"
            periods           = @($inCurrent)
        }
        Write-Information "[PRP STEP 5] Current partial fiscal year: $currentFyLabel — $($inCurrent.Count) period(s)" -Tags PRP
    }
}

if ($selectedScope) {
    $detail = "Scope: FY$($selectedScope.fiscal_year_label) ($($selectedScope.mode)) — $($selectedScope.periods.Count) period(s)"
    Write-Information "[PRP STEP 5] PASSED — $detail" -Tags PRP
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $true
        Details       = $detail
        SelectedScope = $selectedScope
    }
} else {
    $detail = "Could not determine scope from $($parsedPeriods.Count) period(s)"
    Write-Warning "[PRP STEP 5] FAILED — $detail"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber    = $stepNumber
        Passed        = $false
        Details       = $detail
        SelectedScope = $null
        NextSteps     = @("No reconcilable period found. Specify -FiscalYear or -PeriodEnd manually. Available periods: $($parsedPeriods | ForEach-Object { $_.period_end.ToString('yyyy-MM-dd') } -join ', ')")
    }
}
