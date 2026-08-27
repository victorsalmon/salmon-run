# Zoho.BankAccounts — bank account discovery.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH (same as Expenses).
# Capabilities: zoho:bankaccount:read.

function Get-ZohoBankAccounts {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string[]]$AccountNameFilter = @("TD", "SCOTIA", "RBC")
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $result = Invoke-ZohoExpenseApi -Method GET -Endpoint "/bankaccounts" -OrganizationId $orgId
    if (-not $result.Success) {
        return $result
    }

    $allAccounts = $result.Data.bankaccounts
    if (-not $allAccounts) {
        return [pscustomobject]@{ Success = $true; Data = @() }
    }

    $filtered = $allAccounts | Where-Object {
        $name = $_.account_name
        $matched = $false
        foreach ($filter in $AccountNameFilter) {
            if ($name -like "*$filter*") { $matched = $true; break }
        }
        $matched
    }

    $resultData = $filtered | ForEach-Object {
        [pscustomobject]@{
            account_id   = $_.account_id
            account_name = $_.account_name
            currency_id  = $_.currency_id
            is_active    = $_.is_active
            account_type = $_.account_type
        }
    }

    Write-BookkeepingAuditEntry -Capability 'zoho:bankaccount:read' -Action "Get-ZohoBankAccounts" -Context @{ OrgName = $OrgName; Count = $resultData.Count } -Result 'allow'
    return [pscustomobject]@{ Success = $true; Data = $resultData }
}
