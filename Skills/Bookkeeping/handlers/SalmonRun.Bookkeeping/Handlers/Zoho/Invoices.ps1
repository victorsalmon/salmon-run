# Zoho.Invoices — invoice discovery and creation.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH.
# Capabilities: zoho:invoice:read, zoho:invoice:write.

function Invoke-ZohoInvoicesApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        $Body = $null,
        [string]$OrganizationId,
        $QueryParams = $null
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:invoice:read'

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
        $action = "zoho:invoice:$($Method.ToLowerInvariant())"
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

function Get-ZohoInvoices {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$Status,           # 'draft', 'sent', 'overdue', 'paid', 'void', 'unpaid', 'partially_paid'
        [string]$CustomerId,
        [string]$FromDate,
        [string]$ToDate,
        [int]$Page = 1,
        [int]$PerPage = 200
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:invoice:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $queryParams = @{ page = $Page; per_page = [math]::Min($PerPage, 200) }
    if ($Status) { $queryParams.status = $Status }
    if ($CustomerId) { $queryParams.customer_id = $CustomerId }
    if ($FromDate) { $queryParams.date_start = $FromDate }
    if ($ToDate) { $queryParams.date_end = $ToDate }

    $result = Invoke-ZohoInvoicesApi -Method GET -Endpoint "/invoices" -OrganizationId $orgId -QueryParams $queryParams
    if ($result.Success) {
        $invoices = @()
        if ($result.Data.invoices) {
            $invoices = $result.Data.invoices | ForEach-Object {
                [pscustomobject]@{
                    InvoiceId      = $_.invoice_id
                    InvoiceNumber  = $_.invoice_number
                    CustomerId     = $_.customer_id
                    CustomerName   = $_.customer_name
                    Status         = $_.status
                    Total          = $_.total
                    Balance        = $_.balance
                    Date           = $_.date
                    DueDate        = $_.due_date
                    CurrencyCode   = $_.currency_code
                    Email          = $_.email
                }
            }
        }
        Write-BookkeepingAuditEntry -Capability 'zoho:invoice:read' -Action "Get-ZohoInvoices" -Context @{ OrgName = $OrgName; Count = $invoices.Count } -Result 'allow'
        return [pscustomobject]@{
            Success  = $true
            Invoices = $invoices
            PageContext = if ($result.Data.page_context) { $result.Data.page_context } else { $null }
        }
    }
    return $result
}

function New-ZohoInvoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CustomerId,
        [string]$OrgName = 'Intersite',
        [string]$InvoiceNumber,
        [string]$Date,
        [string]$DueDate,
        [decimal]$ExchangeRate = 1,
        [string]$ReferenceNumber,
        [string]$Notes,
        [string]$Terms,
        [hashtable[]]$LineItems   # Each item: { name, rate, quantity, description, account_id, tax_id }
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:invoice:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        customer_id = $CustomerId
    }
    if ($InvoiceNumber) { $body.invoice_number = $InvoiceNumber }
    if ($Date) { $body.date = $Date }
    if ($DueDate) { $body.due_date = $DueDate }
    if ($ReferenceNumber) { $body.reference_number = $ReferenceNumber }
    if ($Notes) { $body.notes = $Notes }
    if ($Terms) { $body.terms = $Terms }
    if ($ExchangeRate) { $body.exchange_rate = [double]$ExchangeRate }
    if ($LineItems -and $LineItems.Count -gt 0) { $body.line_items = $LineItems }

    $result = Invoke-ZohoInvoicesApi -Method POST -Endpoint "/invoices" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.invoice) {
        $inv = $result.Data.invoice
        Write-BookkeepingAuditEntry -Capability 'zoho:invoice:write' -Action "New-ZohoInvoice" -Context @{ InvoiceId = $inv.invoice_id } -Result 'allow'
        return [pscustomobject]@{
            Success       = $true
            InvoiceId     = $inv.invoice_id
            InvoiceNumber = $inv.invoice_number
            Status        = $inv.status
            Total         = $inv.total
            Balance       = $inv.balance
        }
    }
    return $result
}
