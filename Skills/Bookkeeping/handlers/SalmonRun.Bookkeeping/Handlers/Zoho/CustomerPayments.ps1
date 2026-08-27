# Zoho.CustomerPayments — customer payment creation against invoices.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH.
# Capabilities: zoho:invoice:write (customer payments are invoice-related).

function Invoke-ZohoCustomerPaymentsApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        $Body = $null,
        [string]$OrganizationId,
        $QueryParams = $null
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:invoice:write'

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
        $action = "zoho:customerpayment:$($Method.ToLowerInvariant())"
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

function New-ZohoCustomerPayment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CustomerId,
        [Parameter(Mandatory)][decimal]$Amount,
        [Parameter(Mandatory)][string]$Date,
        [Parameter(Mandatory)][string]$PaymentMode,
        [hashtable[]]$Invoices,
        [string]$OrgName = 'Intersite',
        [string]$AccountId,
        [string]$ReferenceNumber,
        [string]$Description,
        [decimal]$ExchangeRate = 1
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:invoice:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        customer_id   = $CustomerId
        amount        = [double]$Amount
        date          = $Date
        payment_mode  = $PaymentMode
        exchange_rate = [double]$ExchangeRate
    }
    if ($AccountId) { $body.account_id = $AccountId }
    if ($ReferenceNumber) { $body.reference_number = $ReferenceNumber }
    if ($Description) { $body.description = $Description }
    if ($Invoices -and $Invoices.Count -gt 0) {
        $body.invoices = @($Invoices | ForEach-Object {
            @{
                invoice_id    = $_.invoice_id
                amount_applied = [double]$_.amount_applied
            }
        })
    }

    $result = Invoke-ZohoCustomerPaymentsApi -Method POST -Endpoint "/customerpayments" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.payment) {
        $p = $result.Data.payment
        Write-BookkeepingAuditEntry -Capability 'zoho:invoice:write' -Action "New-ZohoCustomerPayment" -Context @{
            PaymentId = $p.payment_id; CustomerId = $CustomerId; Amount = $Amount
        } -Result 'allow'
        return [pscustomobject]@{
            Success           = $true
            PaymentId         = $p.payment_id
            PaymentNumber     = $p.payment_number
            Date              = $p.date
            Amount            = $p.amount
            PaymentMode       = $p.payment_mode
            InvoicesProcessed = if ($p.invoices) { ($p.invoices | Measure-Object).Count } else { 0 }
        }
    }
    return $result
}
