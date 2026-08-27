# Zoho.BankTransactions — bank transaction retrieval for reconciliation.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH (same as Expenses).
# Capabilities: zoho:expense:read.

function Get-ZohoBankTransactions {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$Month
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $startDate = "$Month-01"
    $endDate = (Get-Date "$Month-01").AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd')

    $accountsResult = Invoke-ZohoExpenseApi -Method GET -Endpoint "/bankaccounts" -OrganizationId $orgId
    if (-not $accountsResult.Success) {
        return $accountsResult
    }
    $accounts = $accountsResult.Data.bankaccounts
    if (-not $accounts) {
        return [pscustomobject]@{
            Success = $true
            month = $Month
            total_accounts = 0
            accounts = @()
            zoho_count = 0
            reconciled_count = 0
            unreconciled_count = 0
        }
    }

    $allAccounts = @()
    $totalTransactions = 0
    $totalReconciled = 0
    $totalUnreconciled = 0

    foreach ($acct in $accounts) {
        $page = 1
        do {
            $queryParams = @{
                account_id = $acct.account_id
                date_start = $startDate
                date_end   = $endDate
                per_page   = 200
                page       = $page
            }
            $txnResult = Invoke-ZohoExpenseApi -Method GET -Endpoint "/banktransactions" -OrganizationId $orgId -QueryParams $queryParams
            if (-not $txnResult.Success) {
                break
            }
            $txns = $txnResult.Data.banktransactions
            if (-not $txns) { break }
            $hasMore = $txnResult.Data.page_context.has_more_page

            $txnCount = $txns.Count
            $reconciledCount = ($txns | Where-Object { $_.status -eq 'reconciled' -or $_.is_reconciled -eq $true }).Count
            $unreconciledCount = $txnCount - $reconciledCount

            $totalTransactions += $txnCount
            $totalReconciled += $reconciledCount
            $totalUnreconciled += $unreconciledCount

            $allAccounts += [pscustomobject]@{
                account_id   = $acct.account_id
                account_name = $acct.account_name
                total        = $txnCount
                reconciled   = $reconciledCount
                unreconciled = $unreconciledCount
            }

            $page++
        } while ($hasMore)
    }

    Write-BookkeepingAuditEntry -Capability 'zoho:expense:read' -Action "Get-ZohoBankTransactions" -Context @{ OrgName = $OrgName; Month = $Month; Accounts = $allAccounts.Count; Total = $totalTransactions } -Result 'allow'

    return [pscustomobject]@{
        Success = $true
        month = $Month
        total_accounts = $allAccounts.Count
        accounts = $allAccounts
        zoho_count = $totalTransactions
        reconciled_count = $totalReconciled
        unreconciled_count = $totalUnreconciled
    }
}

function New-ZohoBankTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][decimal]$Amount,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][ValidateSet('debit', 'credit')][string]$DebitOrCredit,
        [string]$OrgName = 'Intersite',
        [string]$Payee,
        [string]$Description
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        account_id = $AccountId
        amount = [double]$Amount
        date = $Date
        debit_or_credit = $DebitOrCredit
    }
    if ($Payee) { $body.payee = $Payee }
    if ($Description) { $body.description = $Description }

    $result = Invoke-ZohoExpenseApi -Method POST -Endpoint "/banktransactions" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.banktransaction) {
        $bt = $result.Data.banktransaction
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:write' -Action "New-ZohoBankTransaction" -Context @{
            AccountId = $AccountId; Amount = $Amount; Date = $Date; OrgName = $OrgName
        } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            TransactionId = $bt.transaction_id
            BankTransactionId = $bt.bank_transaction_id
            Date = $bt.date
            Amount = $bt.amount
            Status = $bt.status
        }
    }
    return $result
}
