# Zoho.Contacts — contact (customer/vendor) discovery and creation.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH.
# Capabilities: zoho:contact:read, zoho:contact:write.

function Invoke-ZohoContactsApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        $Body = $null,
        [string]$OrganizationId,
        $QueryParams = $null
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:contact:read'

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
        $action = "zoho:contact:$($Method.ToLowerInvariant())"
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

function Get-ZohoContacts {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$ContactType,   # 'customer' or 'vendor'
        [string]$SearchText,
        [string]$Email,
        [int]$Page = 1,
        [int]$PerPage = 200
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:contact:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $queryParams = @{ page = $Page; per_page = [math]::Min($PerPage, 200) }
    if ($ContactType) { $queryParams.contact_type = $ContactType }
    if ($SearchText) { $queryParams.search_text = $SearchText }
    if ($Email) { $queryParams.email = $Email }

    $result = Invoke-ZohoContactsApi -Method GET -Endpoint "/contacts" -OrganizationId $orgId -QueryParams $queryParams
    if ($result.Success) {
        $contacts = @()
        if ($result.Data.contacts) {
            $contacts = $result.Data.contacts | ForEach-Object {
                [pscustomobject]@{
                    ContactId    = $_.contact_id
                    ContactName  = $_.contact_name
                    ContactType  = $_.contact_type
                    Email        = $_.email
                    Phone        = $_.phone
                    Mobile       = $_.mobile
                    CompanyName  = $_.company_name
                    Status       = $_.status
                    CurrencyCode = $_.currency_code
                    Outstanding  = $_.outstanding_receivable_amount
                    Payables     = $_.outstanding_payable_amount
                }
            }
        }
        Write-BookkeepingAuditEntry -Capability 'zoho:contact:read' -Action "Get-ZohoContacts" -Context @{ OrgName = $OrgName; Count = $contacts.Count } -Result 'allow'
        return [pscustomobject]@{
            Success  = $true
            Contacts = $contacts
            PageContext = if ($result.Data.page_context) { $result.Data.page_context } else { $null }
        }
    }
    return $result
}

function New-ZohoContact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContactName,
        [Parameter(Mandatory)][string]$ContactType,   # 'customer' or 'vendor'
        [string]$OrgName = 'Intersite',
        [string]$Email,
        [string]$Phone,
        [string]$Mobile,
        [string]$CompanyName,
        [string]$CurrencyCode,
        [string]$Notes
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:contact:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        contact_name  = $ContactName
        contact_type  = $ContactType
    }
    if ($Email) { $body.email = $Email }
    if ($Phone) { $body.phone = $Phone }
    if ($Mobile) { $body.mobile = $Mobile }
    if ($CompanyName) { $body.company_name = $CompanyName }
    if ($CurrencyCode) { $body.currency_code = $CurrencyCode }
    if ($Notes) { $body.notes = $Notes }

    $result = Invoke-ZohoContactsApi -Method POST -Endpoint "/contacts" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.contact) {
        $c = $result.Data.contact
        Write-BookkeepingAuditEntry -Capability 'zoho:contact:write' -Action "New-ZohoContact" -Context @{ ContactId = $c.contact_id; ContactName = $ContactName } -Result 'allow'
        return [pscustomobject]@{
            Success     = $true
            ContactId   = $c.contact_id
            ContactName = $c.contact_name
            ContactType = $c.contact_type
            Status      = $c.status
        }
    }
    return $result
}
