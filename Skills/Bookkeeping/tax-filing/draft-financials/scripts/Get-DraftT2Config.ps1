<#
.SYNOPSIS
    Loads Draft T2 Filing configuration from the year-specific PSD1 data file.
.DESCRIPTION
    Reads tax rates, business limits, GIFI line mapping, CCA class defaults, and
    prior year data from the corresponding tax-year-<year>.psd1 file. Returns a
    PSCustomObject for dot-notation access by all schedule scripts.

    To add a new tax year: copy tax-year-2026.psd1 → tax-year-<year>.psd1 and
    update only the values that changed. Then call Get-DraftT2Config with the
    new fiscal year end.
.PARAMETER FiscalYearEnd
    Fiscal year end date string (default: "2026-03-31"). Used to discover the
    correct tax-year-<year>.psd1 file. The year is extracted from the last 4
    characters before the hyphen-replaced dash.
.PARAMETER EntityName
    Legal entity name (default: "Intersite Consulting Inc.").
.PARAMETER Override
    Optional hashtable of values to override config after loading. Keys match
    the returned object's property paths using dot-notation (e.g.
    @{ "tax_rates.federal_part_i_rate_before_sbd" = 0.15 }).
.EXAMPLE
    $cfg = .\Get-DraftT2Config.ps1
    $cfg.tax_rates.federal_part_i_rate_before_sbd  # 0.28
.EXAMPLE
    $cfg = .\Get-DraftT2Config.ps1 -Override @{ "business_limits.federal" = 510000 }
#>
function Get-DraftT2Config {
    [CmdletBinding()]
    param(
        [string]$FiscalYearEnd = "2026-03-31",
        [string]$EntityName = "Intersite Consulting Inc.",
        [hashtable]$Override = @{}
    )

    function ConvertTo-PSCustomObject {
        param([object]$InputObject)
        if ($InputObject -is [hashtable]) {
            $obj = [PSCustomObject]@{}
            foreach ($key in $InputObject.Keys) {
                $val = ConvertTo-PSCustomObject -InputObject $InputObject[$key]
                $obj | Add-Member -MemberType NoteProperty -Name $key -Value $val -Force
            }
            return $obj
        } elseif ($InputObject -is [array]) {
            return @($InputObject | ForEach-Object { ConvertTo-PSCustomObject -InputObject $_ })
        } elseif ($InputObject -is [System.Collections.IDictionary]) {
            $obj = [PSCustomObject]@{}
            foreach ($key in $InputObject.Keys) {
                $val = ConvertTo-PSCustomObject -InputObject $InputObject[$key]
                $obj | Add-Member -MemberType NoteProperty -Name $key -Value $val -Force
            }
            return $obj
        } else {
            return $InputObject
        }
    }

    $scriptDir = Split-Path $PSCommandPath -Parent
    $year = ($FiscalYearEnd -split '-')[0]
    $psd1Path = Join-Path $scriptDir "..\..\tax-year-$year.psd1"

    if (-not (Test-Path $psd1Path)) {
        throw "Tax year data file not found: $psd1Path. Create tax-year-$year.psd1 (copy from an existing year file and update values)."
    }

    $rawConfig = Import-PowerShellDataFile $psd1Path
    $config = ConvertTo-PSCustomObject -InputObject $rawConfig

    $config | Add-Member -MemberType NoteProperty -Name fiscal_year_end -Value $FiscalYearEnd -Force
    $config | Add-Member -MemberType NoteProperty -Name entity -Value $EntityName -Force

    foreach ($key in $Override.Keys) {
        $parts = $key -split "\."
        $target = $config
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $target = $target.$($parts[$i])
        }
        $target.$($parts[-1]) = $Override[$key]
    }

    return $config
}

if ($MyInvocation.InvocationName -eq '&' -or $MyInvocation.Line -match '\.\\Get-DraftT2Config') {
    Get-DraftT2Config
}
