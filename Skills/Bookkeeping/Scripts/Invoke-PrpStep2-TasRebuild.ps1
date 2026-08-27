<#
.SYNOPSIS
    PRP Step 2: Rebuild TAS as temporary working file from Zoho data.
.DESCRIPTION
    TAS is no longer a permanent artifact — must be assumed stale. Rebuilds
    a fresh working TAS from bulk-fetched Zoho data. Session-scoped file
    written to Tasks/Tmp/, discarded at end of pipeline.
.PARAMETER ZohoAll
    Bulk-fetched Zoho transactions and expenses array (post-CR+DR sweep).
.PARAMETER OrgName
    Organization name (e.g. "intersite-consulting" or "room-rentals").
.PARAMETER AccountName
    Account slug name for working file naming.
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
    Invoke-PrpStep2-TasRebuild.ps1 -ZohoAll $zohoAll -OrgName "intersite-consulting" -AccountName "RBC-INTERSITE"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [array]$ZohoAll,

    [Parameter()]
    [array]$UncatTxns,

    [Parameter()]
    [array]$AllExpenses,

    [Parameter(Mandatory)]
    [string]$OrgName,

    [Parameter(Mandatory)]
    [string]$AccountName,

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
$stepNumber = 2
$stepName = "TAS Rebuild from Zoho"

Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName

$combined = @()
$combined += $ZohoAll | ForEach-Object {
    $amount = if ($_.debit_or_credit -eq "credit" -or $_.transaction_type -eq "credit") { -[decimal]($_.amount -or 0) } else { [decimal]($_.amount -or 0) }
    [PSCustomObject]@{
        date                 = if ($_.date -is [datetime]) { $_.date.ToString('yyyy-MM-dd') } else { "$($_.date)" }
        description          = $_.description -or $_.vendor_name -or ""
        amount               = $amount
        account_id           = $_.account_id -or ""
        zoho_transaction_id  = $_.transaction_id -or $_.expense_id -or ""
        source               = "zoho"
    }
}
$combined += $UncatTxns | ForEach-Object {
    $amount = if ($_.debit_or_credit -eq "credit" -or $_.transaction_type -eq "credit") { -[decimal]($_.amount -or 0) } else { [decimal]($_.amount -or 0) }
    [PSCustomObject]@{
        date                 = if ($_.date -is [datetime]) { $_.date.ToString('yyyy-MM-dd') } else { "$($_.date)" }
        description          = $_.description -or $_.vendor_name -or ""
        amount               = $amount
        account_id           = $_.account_id -or ""
        zoho_transaction_id  = $_.transaction_id -or ""
        source               = "zoho"
    }
}
$combined += $AllExpenses | ForEach-Object {
    [PSCustomObject]@{
        date                 = if ($_.date -is [datetime]) { $_.date.ToString('yyyy-MM-dd') } else { "$($_.date)" }
        description          = $_.description -or $_.vendor_name -or ""
        amount               = -[decimal]($_.amount -or 0)
        account_id           = $_.account_id -or ""
        zoho_transaction_id  = $_.expense_id -or ""
        source               = "zoho"
    }
}

if ($WhatIfPreference) {
    Write-Information "[PRP STEP 2] WhatIf: would write $($combined.Count) rows to working TAS" -Tags PRP
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $true
        Details        = "WhatIf: TAS rebuild skipped (would produce $($combined.Count) rows)"
        TasWorkingPath = $null
    }
}

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$tmpDir = Join-Path (Resolve-Path "$PSScriptRoot\..\..\..") "Tasks\Tmp"
$null = New-Item -ItemType Directory -Path $tmpDir -Force
$tasPath = Join-Path $tmpDir "tas-working-$OrgName-$AccountName-$ts.csv"

# Dedup only items that have a non-empty zoho_transaction_id; keep all items with null IDs
$hasId = $combined | Where-Object { $_.zoho_transaction_id -and $_.zoho_transaction_id.Trim() -ne "" }
$noId = $combined | Where-Object { -not $_.zoho_transaction_id -or $_.zoho_transaction_id.Trim() -eq "" }
$deduped = @($hasId | Sort-Object zoho_transaction_id -Unique) + @($noId)
$rowCount = $deduped.Count
$totalDebits = [math]::Round(($deduped | Where-Object { $_.amount -gt 0 } | Measure-Object amount -Sum).Sum, 2)
$totalCredits = [math]::Round(($deduped | Where-Object { $_.amount -lt 0 } | Measure-Object amount -Sum).Sum, 2)

$deduped | Select-Object date, description, amount, account_id, zoho_transaction_id, source |
    Export-Csv -LiteralPath $tasPath -NoTypeInformation -Encoding utf8

$expectedTotal = $combined.Count
$dupSwept = $expectedTotal - $rowCount

if ($rowCount -eq $expectedTotal -or $dupSwept -le ($expectedTotal * 0.02)) {
    Write-Information "[PRP STEP 2] PASSED — $rowCount rows written to $tasPath (debits=$totalDebits, credits=$totalCredits, dedup=$dupSwept)" -Tags PRP
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $true
        Details        = "$rowCount rows written to working TAS (dedup=$dupSwept)"
        TasWorkingPath = $tasPath
        RowCount       = $rowCount
        TotalDebits    = $totalDebits
        TotalCredits   = $totalCredits
    }
} else {
    Write-Warning "[PRP STEP 2] FAILED — Row count $rowCount vs expected $expectedTotal (swept $dupSwept)"
    Write-Progress -Activity "[PRP Step $stepNumber]" -Status $stepName -Completed
    return [PSCustomObject]@{
        StepNumber     = $stepNumber
        Passed         = $false
        Details        = "Row count mismatch: $rowCount vs $expectedTotal (dedup threshold exceeded)"
        NextSteps      = @("Check for duplicate zoho_transaction_ids, fix source data, re-run Step 2")
        TasWorkingPath = $null
    }
}
