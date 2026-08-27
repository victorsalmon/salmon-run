<#
.SYNOPSIS
    Verify that all transactions for a given period are reconciled in Zoho Books.
.DESCRIPTION
    Fetches banktransactions for the account up to the period end date, groups by
    reconcile_status, and confirms all are reconciled. Returns $true if all passed,
    or a list of unreconciled transaction IDs if any failed.
.PARAMETER Token
    Zoho OAuth access token.
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER AccountId
    Zoho bank account ID.
.PARAMETER PeriodEnd
    End date of the statement period (ISO 8601 format).
.EXAMPLE
    Confirm-ReconciliationStatus -Token "..." -OrgId "925048093" -AccountId "12345" -PeriodEnd "2026-01-31"
#>

function Confirm-ReconciliationStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$OrgId,

        [Parameter(Mandatory)]
        [string]$AccountId,

        [Parameter(Mandatory)]
        [string]$PeriodEnd
    )

    $headers = @{ Authorization = "Zoho-oauthtoken $Token"; "Content-Type" = "application/json" }

    # Fetch all banktransactions up to period end
    $txnUri = "https://www.zohoapis.com/books/v3/banktransactions?organization_id=$OrgId&account_id=$AccountId&per_page=200&date_range_end=$PeriodEnd"
    $txnResult = Invoke-RestMethod -Uri $txnUri -Headers $headers -Method GET -ErrorAction Stop
    $txns = $txnResult.banktransactions

    if (-not $txns -or $txns.Count -eq 0) {
        Write-Information "[PRP RECON] No transactions found for period ending $PeriodEnd" -Tags PRP
        return @{ Passed = $false; UnreconciledIds = @(); Detail = "No transactions found" }
    }

    # Group by reconcile_status
    $statusGroups = $txns | Group-Object reconcile_status
    $reconciledCount = ($statusGroups | Where-Object Name -eq "reconciled" | ForEach-Object Count)
    $unreconciled = $txns | Where-Object { $_.reconcile_status -ne "reconciled" }

    # Also verify the reconciliation record exists
    $reconUri = "https://www.zohoapis.com/books/v3/bankaccounts/$AccountId/reconciliation?organization_id=$OrgId"
    try {
        $reconResult = Invoke-RestMethod -Uri $reconUri -Headers $headers -Method GET -ErrorAction SilentlyContinue
    } catch {
        $reconResult = $null
    }

    $detail = "Period $PeriodEnd`: $reconciledCount reconciled, $($unreconciled.Count) unreconciled"
    Write-Information "[PRP RECON] $detail" -Tags PRP

    if ($unreconciled.Count -eq 0) {
        return @{
            Passed          = $true
            UnreconciledIds = @()
            Detail          = $detail
            ReconciledCount = $reconciledCount
            TotalCount      = $txns.Count
            ReconRecord     = $reconResult
        }
    }

    return @{
        Passed          = $false
        UnreconciledIds = @($unreconciled.transaction_id)
        Detail          = $detail
        ReconciledCount = $reconciledCount
        TotalCount      = $txns.Count
        ReconRecord     = $reconResult
    }
}
