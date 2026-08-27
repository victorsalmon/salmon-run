# Zoho.ChartOfAccounts — chart-of-accounts discovery and creation.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH.
# Capabilities: zoho:chartofaccount:read, zoho:chartofaccount:write.

function Invoke-ZohoChartOfAccountsApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        $Body = $null,
        [string]$OrganizationId,
        $QueryParams = $null
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:chartofaccount:read'

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
        $action = "zoho:chartofaccounts:$($Method.ToLowerInvariant())"
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

function Get-ZohoChartOfAccounts {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$AccountType,
        [string]$SearchText,
        [int]$Page = 1,
        [int]$PerPage = 200
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:chartofaccount:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $queryParams = @{ page = $Page; per_page = [math]::Min($PerPage, 200) }
    if ($AccountType) { $queryParams.account_type = $AccountType }
    if ($SearchText) { $queryParams.search_text = $SearchText }

    $result = Invoke-ZohoChartOfAccountsApi -Method GET -Endpoint "/chartofaccounts" -OrganizationId $orgId -QueryParams $queryParams
    if ($result.Success) {
        $accounts = @()
        if ($result.Data.chartofaccounts) {
            $accounts = $result.Data.chartofaccounts | ForEach-Object {
                [pscustomobject]@{
                    AccountId        = $_.account_id
                    AccountName      = $_.account_name
                    AccountType      = $_.account_type
                    AccountTypeName  = $_.account_type_formatted
                    CurrencyId       = $_.currency_id
                    CurrencyCode     = $_.currency_code
                    IsActive         = $_.is_active
                    Description      = $_.description
                    ParentAccountId  = $_.parent_account_id
                }
            }
        }
        Write-BookkeepingAuditEntry -Capability 'zoho:chartofaccount:read' -Action "Get-ZohoChartOfAccounts" -Context @{ OrgName = $OrgName; Count = $accounts.Count } -Result 'allow'
        return [pscustomobject]@{
            Success  = $true
            Accounts = $accounts
            PageContext = if ($result.Data.page_context) { $result.Data.page_context } else { $null }
        }
    }
    return $result
}

function New-ZohoChartOfAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountName,
        [Parameter(Mandatory)][string]$AccountType,
        [string]$OrgName = 'Intersite',
        [string]$Description,
        [string]$CurrencyId,
        [string]$ParentAccountId,
        [string]$AccountCode
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:chartofaccount:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        account_name = $AccountName
        account_type = $AccountType
    }
    if ($Description) { $body.description = $Description }
    if ($CurrencyId) { $body.currency_id = $CurrencyId }
    if ($ParentAccountId) { $body.parent_account_id = $ParentAccountId }
    if ($AccountCode) { $body.account_code = $AccountCode }

    $result = Invoke-ZohoChartOfAccountsApi -Method POST -Endpoint "/chartofaccounts" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.chart_of_account) {
        $a = $result.Data.chart_of_account
        Write-BookkeepingAuditEntry -Capability 'zoho:chartofaccount:write' -Action "New-ZohoChartOfAccount" -Context @{ AccountId = $a.account_id; AccountName = $AccountName } -Result 'allow'
        return [pscustomobject]@{
            Success     = $true
            AccountId   = $a.account_id
            AccountName = $a.account_name
            AccountType = $a.account_type
            Status      = $a.status
        }
    }
    return $result
}
