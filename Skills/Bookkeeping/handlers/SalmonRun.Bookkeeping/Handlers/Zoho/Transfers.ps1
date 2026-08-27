# Zoho.Transfers — bank-account transfer management.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH (same as Expenses).
# Capabilities: zoho:transfer:read, zoho:transfer:write.
# Zoho Books API: https://www.zoho.com/books/api/v3/transfers/

function Invoke-ZohoTransfersApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        $Body = $null,
        [string]$OrganizationId,
        $QueryParams = $null
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:transfer:read'

    $accessToken = Get-ZohoAccessToken
    if (-not $accessToken) {
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "No valid access token available" }
    }

    $orgId = if ($OrganizationId) { $OrganizationId } else { $script:ZohoOrgIdIntersite }
    $queryParts = [System.Collections.Generic.List[string]]::new()
    $queryParts.Add("organization_id=$orgId")
    if ($QueryParams -and $QueryParams.Keys.Count -gt 0) {
        foreach ($key in $QueryParams.Keys) {
            $queryParts.Add("$key=$([System.Web.HttpUtility]::UrlEncode($QueryParams[$key]))")
        }
    }
    $url = "$($script:ZohoBaseUrl)${Endpoint}?$($queryParts -join '&')"

    $headers = @{
        Authorization = "Bearer $accessToken"
        "X-com-zoho-books-organizationid" = $orgId
    }

    try {
        $bodyJson = if ($Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { $null }
        $action = "zoho:transfer:$($Method.ToLowerInvariant())"
        $Response = Invoke-ApiCall -Uri $url -Method $Method -Headers $headers -Body $bodyJson -Domain "Bookkeeper" -Action $action -ReturnRaw -TimeoutSec 30

        $StatusCode = [int]$Response.StatusCode
        if ($StatusCode -ge 400) {
            $detail = try { ($Response.Content | ConvertFrom-Json).message } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
            return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $detail }
        }

        $Parsed = $Response.Content | ConvertFrom-Json
        if ($Parsed.code -ne 0) {
            return [pscustomobject]@{ Success = $false; StatusCode = 400; Message = $Parsed.message }
        }
        return [pscustomobject]@{ Success = $true; Data = $Parsed }
    }
    catch {
        $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
        $Detail = "API error"
        if ($_.ErrorDetails) { $Detail = $_.ErrorDetails.Message }
        if ($StatusCode -eq 401) { $script:ZohoAccessTokenExpiry = $null }
        return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
    }
}

function Get-ZohoTransfers {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$TransferId,
        [string]$FromAccountId,
        [string]$ToAccountId,
        [string]$FromDate,
        [string]$ToDate,
        [int]$Page = 1,
        [int]$PerPage = 200
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:transfer:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    if ($TransferId) {
        $result = Invoke-ZohoTransfersApi -Method GET -Endpoint "/transfers/$TransferId" -OrganizationId $orgId
        if ($result.Success -and $result.Data.transfer) {
            $t = $result.Data.transfer
            Write-BookkeepingAuditEntry -Capability 'zoho:transfer:read' -Action "Get-ZohoTransfers" -Context @{ TransferId = $TransferId; OrgName = $OrgName } -Result 'allow'
            return [pscustomobject]@{
                Success = $true
                Transfer = [pscustomobject]@{
                    TransferId   = $t.transfer_id
                    FromAccountId = $t.from_account_id
                    FromAccountName = $t.from_account_name
                    ToAccountId   = $t.to_account_id
                    ToAccountName = $t.to_account_name
                    Date         = $t.date
                    Amount       = $t.amount
                    CurrencyCode = $t.currency_code
                    Description  = $t.description
                    ReferenceNumber = $t.reference_number
                    Status       = $t.status
                }
            }
        }
        return $result
    }

    $queryParams = @{ page = $Page; per_page = [math]::Min($PerPage, 200) }
    if ($FromAccountId) { $queryParams.from_account_id = $FromAccountId }
    if ($ToAccountId) { $queryParams.to_account_id = $ToAccountId }
    if ($FromDate) { $queryParams.date_start = $FromDate }
    if ($ToDate) { $queryParams.date_end = $ToDate }

    $result = Invoke-ZohoTransfersApi -Method GET -Endpoint "/transfers" -OrganizationId $orgId -QueryParams $queryParams
    if ($result.Success) {
        $transfers = @()
        if ($result.Data.transfers) {
            $transfers = $result.Data.transfers | ForEach-Object {
                [pscustomobject]@{
                    TransferId      = $_.transfer_id
                    FromAccountId   = $_.from_account_id
                    FromAccountName = $_.from_account_name
                    ToAccountId     = $_.to_account_id
                    ToAccountName   = $_.to_account_name
                    Date            = $_.date
                    Amount          = $_.amount
                    CurrencyCode    = $_.currency_code
                    Description     = $_.description
                    ReferenceNumber = $_.reference_number
                    Status          = $_.status
                }
            }
        }
        Write-BookkeepingAuditEntry -Capability 'zoho:transfer:read' -Action "Get-ZohoTransfers" -Context @{ OrgName = $OrgName; Count = $transfers.Count } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            Transfers = $transfers
            PageContext = if ($result.Data.page_context) { $result.Data.page_context } else { $null }
        }
    }
    return $result
}

function New-ZohoTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromAccountId,
        [Parameter(Mandatory)][string]$ToAccountId,
        [Parameter(Mandatory)][decimal]$Amount,
        [Parameter(Mandatory)][string]$Date,
        [string]$OrgName = 'Intersite',
        [string]$Description,
        [string]$CurrencyId,
        [decimal]$ExchangeRate = 1,
        [string]$ReferenceNumber
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:transfer:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        from_account_id = $FromAccountId
        to_account_id   = $ToAccountId
        amount          = [double]$Amount
        date            = $Date
    }
    if ($Description) { $body.description = $Description }
    if ($CurrencyId) { $body.currency_id = $CurrencyId }
    if ($ExchangeRate -ne 1) { $body.exchange_rate = [double]$ExchangeRate }
    if ($ReferenceNumber) { $body.reference_number = $ReferenceNumber }

    $result = Invoke-ZohoTransfersApi -Method POST -Endpoint "/transfers" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.transfer) {
        $t = $result.Data.transfer
        Write-BookkeepingAuditEntry -Capability 'zoho:transfer:write' -Action "New-ZohoTransfer" -Context @{
            FromAccountId = $FromAccountId; ToAccountId = $ToAccountId; Amount = $Amount; OrgName = $OrgName
        } -Result 'allow'
        return [pscustomobject]@{
            Success         = $true
            TransferId      = $t.transfer_id
            FromAccountId   = $t.from_account_id
            ToAccountId     = $t.to_account_id
            Amount          = $t.amount
            Date            = $t.date
            Status          = $t.status
        }
    }
    return $result
}
