# Zoho.Reports — financial report retrieval (P&L, Trial Balance, Balance Sheet, GL, Tax Summary).
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH.
# Capabilities: zoho:report:read.

function Invoke-ZohoReportsApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][hashtable]$QueryParams
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:report:read'

    $accessToken = Get-ZohoAccessToken
    if (-not $accessToken) {
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "No valid access token available" }
    }

    $orgId = if ($QueryParams.OrgName -and $QueryParams.OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }
    $queryParts = [System.Collections.Generic.List[string]]::new()
    $queryParts.Add("organization_id=$orgId")
    if ($QueryParams.FromDate) { $queryParts.Add("from_date=$([System.Web.HttpUtility]::UrlEncode($QueryParams.FromDate))") }
    if ($QueryParams.ToDate) { $queryParts.Add("to_date=$([System.Web.HttpUtility]::UrlEncode($QueryParams.ToDate))") }
    if ($QueryParams.AccountId) { $queryParts.Add("account_id=$([System.Web.HttpUtility]::UrlEncode($QueryParams.AccountId))") }
    $url = "$($script:ZohoBaseUrl)${Endpoint}?$($queryParts -join '&')"

    $headers = @{
        Authorization = "Bearer $accessToken"
        "X-com-zoho-books-organizationid" = $orgId
    }

    try {
        $Response = Invoke-ApiCall -Uri $url -Method GET -Headers $headers -Domain "Bookkeeper" -Action "zoho:reports:get" -ReturnRaw -TimeoutSec 60

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

function Get-ZohoProfitAndLoss {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromDate,
        [Parameter(Mandatory)][string]$ToDate,
        [string]$OrgName = 'Intersite'
    )

    $queryParams = @{ FromDate = $FromDate; ToDate = $ToDate; OrgName = $OrgName }
    $result = Invoke-ZohoReportsApi -Endpoint "/reports/profitandloss" -QueryParams $queryParams
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:report:read' -Action "Get-ZohoProfitAndLoss" -Context @{ OrgName = $OrgName; FromDate = $FromDate; ToDate = $ToDate } -Result 'allow'
    }
    return $result
}

function Get-ZohoTrialBalance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromDate,
        [Parameter(Mandatory)][string]$ToDate,
        [string]$OrgName = 'Intersite'
    )

    $queryParams = @{ FromDate = $FromDate; ToDate = $ToDate; OrgName = $OrgName }
    $result = Invoke-ZohoReportsApi -Endpoint "/reports/trialbalance" -QueryParams $queryParams
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:report:read' -Action "Get-ZohoTrialBalance" -Context @{ OrgName = $OrgName; FromDate = $FromDate; ToDate = $ToDate } -Result 'allow'
    }
    return $result
}

function Get-ZohoBalanceSheet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromDate,
        [Parameter(Mandatory)][string]$ToDate,
        [string]$OrgName = 'Intersite'
    )

    $queryParams = @{ FromDate = $FromDate; ToDate = $ToDate; OrgName = $OrgName }
    $result = Invoke-ZohoReportsApi -Endpoint "/reports/balancesheet" -QueryParams $queryParams
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:report:read' -Action "Get-ZohoBalanceSheet" -Context @{ OrgName = $OrgName; FromDate = $FromDate; ToDate = $ToDate } -Result 'allow'
    }
    return $result
}

function Get-ZohoGeneralLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromDate,
        [Parameter(Mandatory)][string]$ToDate,
        [string]$OrgName = 'Intersite'
    )

    $queryParams = @{ FromDate = $FromDate; ToDate = $ToDate; OrgName = $OrgName }
    $result = Invoke-ZohoReportsApi -Endpoint "/reports/generalledger" -QueryParams $queryParams
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:report:read' -Action "Get-ZohoGeneralLedger" -Context @{ OrgName = $OrgName; FromDate = $FromDate; ToDate = $ToDate } -Result 'allow'
    }
    return $result
}

function Get-ZohoTaxSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromDate,
        [Parameter(Mandatory)][string]$ToDate,
        [string]$OrgName = 'Intersite'
    )

    $queryParams = @{ FromDate = $FromDate; ToDate = $ToDate; OrgName = $OrgName }
    $result = Invoke-ZohoReportsApi -Endpoint "/reports/taxsummary" -QueryParams $queryParams
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:report:read' -Action "Get-ZohoTaxSummary" -Context @{ OrgName = $OrgName; FromDate = $FromDate; ToDate = $ToDate } -Result 'allow'
    }
    return $result
}

function Get-ZohoAccountGeneralLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FromDate,
        [Parameter(Mandatory)][string]$ToDate,
        [Parameter(Mandatory)][string]$AccountId,
        [string]$OrgName = 'Intersite'
    )

    $queryParams = @{ FromDate = $FromDate; ToDate = $ToDate; OrgName = $OrgName; AccountId = $AccountId }
    $result = Invoke-ZohoReportsApi -Endpoint "/reports/generalledger" -QueryParams $queryParams
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:report:read' -Action "Get-ZohoAccountGeneralLedger" -Context @{ OrgName = $OrgName; FromDate = $FromDate; ToDate = $ToDate; AccountId = $AccountId } -Result 'allow'
    }
    return $result
}
