<#
.SYNOPSIS
    Load PRP per-org configuration JSON.
.DESCRIPTION
    Reads the config file for the given org and returns the parsed object.
    Falls back to sensible defaults if no config file exists.
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting", "room-rentals").
.PARAMETER AccountName
    Optional: return only this account's config section.
.EXAMPLE
    $cfg = Get-PrpConfig -OrgName "intersite-consulting"
    $cfg.accounts["RBC-INTERSITE"].date_tolerance_days
#>

function Get-PrpConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OrgName,

        [Parameter()]
        [string]$AccountName
    )

    $scriptDir = Split-Path -Parent $PSCommandPath
    $configDir = Join-Path (Split-Path -Parent $scriptDir) "config"
    $configFile = Join-Path $configDir "prp-$OrgName.json"

    if (Test-Path -LiteralPath $configFile) {
        $config = Get-Content $configFile -Raw | ConvertFrom-Json
    } else {
        Write-Warning "[PRP CONFIG] No config file found at $configFile — using built-in defaults"
        $config = [PSCustomObject]@{
            org = [PSCustomObject]@{
                name = $OrgName
                fiscal_year_start = "2025-04-01"
                fiscal_year_end = "2026-03-31"
            }
            accounts = [PSCustomObject]@{}
        }
    }

    if ($AccountName) {
        $acctConfig = $config.accounts.$AccountName
        if (-not $acctConfig) {
            Write-Warning "[PRP CONFIG] No config for account '$AccountName' — using defaults"
            $acctConfig = [PSCustomObject]@{
                date_tolerance_days = 2
                opening_balance = 0
                is_credit_card = $false
            }
        }
        return $acctConfig
    }

    return $config
}
