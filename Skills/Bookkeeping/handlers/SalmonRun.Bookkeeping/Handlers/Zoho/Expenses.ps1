# Zoho.Expenses — capability gate for receipt-related operations.
# Auth state (token, circuit breaker) lives in Auth.ps1 (dot-sourced first by the module loader).
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH, ZOHO_BOOKS_ORG_INTERSITE, ZOHO_BOOKS_ORG_RENTALS.
# Capabilities: zoho:expense:read, zoho:expense:write, zoho:expense:attach.

function Invoke-ZohoExpenseApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Endpoint,
        $Body = $null,
        [string]$OrganizationId,
        $QueryParams = $null
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read'

    # Check circuit breaker before making any Zoho call
    if ($script:ZohoCircuitBreakerExpiry -and (Get-Date) -lt $script:ZohoCircuitBreakerExpiry) {
        $expiryStr = $script:ZohoCircuitBreakerExpiry.ToString('o')
        return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Circuit breaker active until $expiryStr" }
    }

    $accessToken = Get-ZohoAccessToken
    if (-not $accessToken) {
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "No valid access token available" }
    }

    $orgId = if ($OrganizationId) { $OrganizationId } else { $script:ZohoOrgIdIntersite }
    $queryParts = [System.Collections.Generic.List[string]]::new()
    $queryParts.Add("organization_id=$orgId")
    if ($QueryParams -and $QueryParams.Count -gt 0) {
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
        $action = "zoho:expense:$($Method.ToLowerInvariant())"
        $Response = Invoke-ApiCall -Uri $url -Method $Method -Headers $headers -Body $bodyJson -Domain "Bookkeeper" -Action $action -ReturnRaw -TimeoutSec 30

        $StatusCode = [int]$Response.StatusCode

        # Circuit breaker on 429 — check Retry-After header
        if ($StatusCode -eq 429) {
            $retryAfter = 60
            if ($Response.Headers -and $Response.Headers['Retry-After']) {
                $retryAfter = [int]::TryParse($Response.Headers['Retry-After'], [ref]$retryAfter) ? $retryAfter : 60
            }
            $script:ZohoCircuitBreakerExpiry = (Get-Date).AddSeconds($retryAfter + 5)
            $detail = try { ($Response.Content | ConvertFrom-Json).message } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
            return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = $detail; CircuitBreakerExpiry = $script:ZohoCircuitBreakerExpiry.ToString('o') }
        }

        if ($StatusCode -ge 400) {
            $detail = try { ($Response.Content | ConvertFrom-Json).message } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
            return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $detail }
        }

        # Invoke-ApiCall -ReturnRaw uses Invoke-WebRequest internally, so
        # $Response.Content is a JSON string and must be parsed. This is NOT a
        # double-parse — the -ReturnRaw path returns the raw response object,
        # not a pre-parsed PSObject.
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
        if ($StatusCode -eq 401) {
            $script:ZohoAccessTokenExpiry = $null
            # Attempt one token refresh
            $script:ZohoAccessTokenValue = $null
            $refreshed = Get-ZohoAccessToken
            if (-not $refreshed) {
                $script:ZohoCircuitBreakerExpiry = (Get-Date).AddSeconds(65)
            }
        }
        return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
    }
}

function Get-ZohoExpense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpenseId,
        [string]$OrgName = 'Intersite'
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $result = Invoke-ZohoExpenseApi -Method GET -Endpoint "/expenses/$ExpenseId" -OrganizationId $orgId
    if ($result.Success -and $result.Data.expense) {
        $e = $result.Data.expense
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:read' -Action "Get-ZohoExpense" -Context @{ ExpenseId = $ExpenseId } -Result 'allow'
        # NOTE: Zoho's API returns receipts via the `documents[]` array; the
        # `receipt_url` field on the expense object is always null. ReceiptUrl is
        # kept here for backward compatibility with existing callers.
        $documents = if ($null -ne $e.documents) { @($e.documents) } else { @() }
        $hasAttachment = [bool]$e.has_attachment -or $documents.Count -gt 0
        return [pscustomobject]@{
            ExpenseId        = $e.expense_id
            Date             = $e.date
            VendorName       = $e.vendor_name
            Amount           = $e.amount
            Currency         = $e.currency
            CategoryName     = $e.account_name
            AccountName      = $e.account_name
            ReceiptUrl       = $e.receipt_url
            Documents        = $documents
            HasAttachment    = $hasAttachment
            AttachmentStatus = if ($hasAttachment) { 'attached' } else { 'unattached' }
            Status           = $e.status
        }
    }
    return $result
}

function Get-ZohoExpenses {
    [CmdletBinding()]
    param(
        [string]$OrgName = 'Intersite',
        [string]$FromDate,
        [string]$ToDate,
        [string]$Vendor,
        [string]$AccountId,
        [int]$Page = 1,
        [int]$PerPage = 200
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $queryParams = @{ page = $Page; per_page = [math]::Min($PerPage, 200) }
    if ($FromDate) { $queryParams.date_start = $FromDate }
    if ($ToDate) { $queryParams.date_end = $ToDate }
    if ($Vendor) { $queryParams.vendor_name = $Vendor }
    if ($AccountId) { $queryParams.account_id = $AccountId }

    $result = Invoke-ZohoExpenseApi -Method GET -Endpoint "/expenses" -OrganizationId $orgId -QueryParams $queryParams
    if ($result.Success) {
        $expenses = @()
        if ($result.Data.expenses) {
            $expenses = $result.Data.expenses | ForEach-Object {
                # Zoho returns `has_attachment` on each expense (the `has_receipt`
                # field does not exist on the /expenses list endpoint). We expose
                # HasAttachment as the canonical property and keep HasReceipt as a
                # compatibility alias for existing callers.
                $hasAttachment = [bool]$_.has_attachment
                [pscustomobject]@{
                    ExpenseId    = $_.expense_id
                    Date         = $_.date
                    VendorName   = $_.vendor_name
                    Amount       = $_.amount
                    Currency     = $_.currency
                    CategoryName = $_.account_name
                    Status       = $_.status
                    HasAttachment = $hasAttachment
                    HasReceipt   = $hasAttachment
                }
            }
        }
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:read' -Action "Get-ZohoExpenses" -Context @{ OrgName = $OrgName; Count = $expenses.Count } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            Expenses = $expenses
            PageContext = if ($result.Data.page_context) { $result.Data.page_context } else { $null }
        }
    }
    return $result
}

function New-ZohoExpense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountId,
        [Parameter(Mandatory)][decimal]$Amount,
        [Parameter(Mandatory)][string]$Date,
        [string]$OrgName = 'Intersite',
        [string]$VendorName,
        [string]$Description,
        [string]$CurrencyId,
        [string]$CustomerId,
        [string]$ProjectId,
        [string]$TransactionId,
        [string]$PaidThroughAccountId,
        [string]$ReceiptBase64,
        [string]$ReceiptPath,
        [string]$ReceiptFileName
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{
        account_id = $AccountId
        amount     = [double]$Amount
        date       = $Date
    }
    if ($VendorName) { $body.vendor_name = $VendorName }
    if ($Description) { $body.description = $Description }
    if ($CurrencyId) { $body.currency_id = $CurrencyId }
    if ($CustomerId) { $body.customer_id = $CustomerId }
    if ($ProjectId) { $body.project_id = $ProjectId }
    if ($TransactionId) { $body.transaction_id = $TransactionId }
    if ($PaidThroughAccountId) { $body.paid_through_account_id = $PaidThroughAccountId }

    $result = Invoke-ZohoExpenseApi -Method POST -Endpoint "/expenses" -Body $body -OrganizationId $orgId
    if ($result.Success -and $result.Data.expense) {
        $e = $result.Data.expense
        $expenseId = $e.expense_id

        $receiptResult = $null
        $effectiveBase64 = $ReceiptBase64
        $effectiveFileName = $ReceiptFileName

        if ($ReceiptPath) {
            if (-not (Test-Path $ReceiptPath)) {
                return [pscustomobject]@{ Success = $false; StatusCode = 404; Message = "Receipt file not found: $ReceiptPath" }
            }
            Write-Information -MessageData "[INFO] Reading receipt from path: $ReceiptPath"
            $effectiveBase64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ReceiptPath))
            if (-not $effectiveFileName) { $effectiveFileName = [System.IO.Path]::GetFileName($ReceiptPath) }
        }

        if ($effectiveBase64) {
            $fileName = if ($effectiveFileName) { $effectiveFileName } else { "receipt_$(Get-Date -Format 'yyyyMMddHHmmss').jpg" }
            $receiptResult = Invoke-ZohoApiWithReceipt -OrganizationId $orgId -ExpenseId $expenseId -ReceiptBase64 $effectiveBase64 -FileName $fileName
        }

        Write-BookkeepingAuditEntry -Capability 'zoho:expense:write' -Action "New-ZohoExpense" -Context @{ ExpenseId = $expenseId; ReceiptSource = if ($ReceiptPath) { 'path' } elseif ($ReceiptBase64) { 'base64' } else { 'none' } } -Result 'allow'
        return [pscustomobject]@{
            ExpenseId   = $e.expense_id
            Amount      = $e.amount
            Date        = $e.date
            VendorName  = $e.vendor_name
            Status      = $e.status
            ReceiptUploaded = if ($receiptResult) { $receiptResult.Success } else { $null }
        }
    }
    return $result
}

function Update-ZohoExpense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpenseId,
        [string]$OrgName = 'Intersite',
        [decimal]$Amount,
        [string]$Date,
        [string]$VendorName,
        [string]$Description
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $body = @{}
    if ($Amount) { $body.amount = [double]$Amount }
    if ($Date) { $body.date = $Date }
    if ($VendorName) { $body.vendor_name = $VendorName }
    if ($Description) { $body.description = $Description }

    $result = Invoke-ZohoExpenseApi -Method PUT -Endpoint "/expenses/$ExpenseId" -Body $body -OrganizationId $orgId
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:write' -Action "Update-ZohoExpense" -Context @{ ExpenseId = $ExpenseId } -Result 'allow'
    }
    return $result
}

function Remove-ZohoExpense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpenseId,
        [string]$OrgName = 'Intersite'
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:write'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    $result = Invoke-ZohoExpenseApi -Method DELETE -Endpoint "/expenses/$ExpenseId" -OrganizationId $orgId
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:write' -Action "Remove-ZohoExpense" -Context @{ ExpenseId = $ExpenseId } -Result 'allow'
    }
    return $result
}

function Attach-ReceiptToExpense {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExpenseId,
        [string]$ReceiptBase64,
        [string]$ReceiptPath,
        [string]$OrgName = 'Intersite',
        [string]$FileName
    )

    Test-BookkeepingCapability -RequiredCapability 'zoho:expense:attach'
    $orgId = if ($OrgName -eq 'RoomRentals') { $script:ZohoOrgIdRoomRentals } else { $script:ZohoOrgIdIntersite }

    if (-not $ReceiptBase64 -and -not $ReceiptPath) {
        return [pscustomobject]@{ Success = $false; StatusCode = 400; Message = "Either ReceiptBase64 or ReceiptPath must be provided" }
    }

    if ($ReceiptPath) {
        if (-not (Test-Path $ReceiptPath)) {
            return [pscustomobject]@{ Success = $false; StatusCode = 404; Message = "Receipt file not found: $ReceiptPath" }
        }
        $ReceiptBase64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ReceiptPath))
        if (-not $FileName) { $FileName = [System.IO.Path]::GetFileName($ReceiptPath) }
    }

    $fileName = if ($FileName) { $FileName } else { "receipt_$(Get-Date -Format 'yyyyMMddHHmmss').jpg" }
    $result = Invoke-ZohoApiWithReceipt -OrganizationId $orgId -ExpenseId $ExpenseId -ReceiptBase64 $ReceiptBase64 -FileName $fileName
    if ($result.Success) {
        Write-BookkeepingAuditEntry -Capability 'zoho:expense:attach' -Action "Attach-ReceiptToExpense" -Context @{ ExpenseId = $ExpenseId } -Result 'allow'
    }
    return $result
}

function Invoke-ZohoApiWithReceipt {
    [CmdletBinding()]
    param(
        [string]$OrganizationId,
        [string]$ExpenseId,
        [string]$ReceiptBase64,
        [string]$FileName
    )

    $accessToken = Get-ZohoAccessToken
    if (-not $accessToken) {
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "No valid access token available" }
    }

    $url = "$($script:ZohoBaseUrl)/expenses/$ExpenseId/receipt?organization_id=$OrganizationId"
    $startTime = Get-Date

    try {
        $boundary = "------------------------" + (Get-Random -Minimum 1000000000 -Maximum 9999999999).ToString()
        $header = "--$boundary`r`nContent-Disposition: form-data; name=`"receipt`"; filename=`"$FileName`"`r`nContent-Type: application/octet-stream`r`n`r`n"
        $footer = "`r`n--$boundary--`r`n"
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($header)
        $imageBytes = [System.Convert]::FromBase64String($ReceiptBase64)
        $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($footer)
        $fullBody = New-Object byte[] ($bodyBytes.Length + $imageBytes.Length + $footerBytes.Length)
        $bodyBytes.CopyTo($fullBody, 0)
        $imageBytes.CopyTo($fullBody, $bodyBytes.Length)
        $footerBytes.CopyTo($fullBody, $bodyBytes.Length + $imageBytes.Length)

        $params = @{
            Uri = $url; Method = "POST"
            Headers = @{
                Authorization = "Bearer $accessToken"
                "X-com-zoho-books-organizationid" = $OrganizationId
                "Content-Type" = "multipart/form-data; boundary=$boundary"
            }
            Body = $fullBody
            ContentType = "multipart/form-data; boundary=$boundary"
            UseBasicParsing = $true
            TimeoutSec = 30
        }
        $Response = Invoke-WebRequest @params -ErrorAction Stop  # Known exception: Invoke-ApiCall doesn't support raw byte-body multipart; audit covered by Write-AuditEntry calls below

        $StatusCode = [int]$Response.StatusCode
        if ($StatusCode -ge 400) {
            $detail = try { ($Response.Content | ConvertFrom-Json).message } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
            $ms = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds, 0)
            Write-AuditEntry -Entry @{ ts = $startTime.ToString('o'); action = "zoho:expense:upload-receipt"; domain = "Bookkeeper"; req = @{ uri = $url; method = "POST" }; res = @{ status = $StatusCode }; error = $detail; ms = $ms } -Domain "Bookkeeper"
            return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $detail }
        }

        $Parsed = $Response.Content | ConvertFrom-Json
        $ms = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds, 0)
        Write-AuditEntry -Entry @{ ts = $startTime.ToString('o'); action = "zoho:expense:upload-receipt"; domain = "Bookkeeper"; req = @{ uri = $url; method = "POST" }; res = @{ status = $StatusCode; body = $Response.Content.Substring(0, [math]::Min(1000, $Response.Content.Length)) }; ms = $ms } -Domain "Bookkeeper"
        return [pscustomobject]@{ Success = ($Parsed.code -eq 0); Data = $Parsed; StatusCode = $StatusCode }
    }
    catch {
        $StatusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode.value__ } else { 0 }
        $Detail = "API error"
        if ($_.ErrorDetails) { $Detail = $_.ErrorDetails.Message }
        if ($StatusCode -eq 401) { $script:ZohoAccessTokenExpiry = $null }
        $ms = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds, 0)
        Write-AuditEntry -Entry @{ ts = $startTime.ToString('o'); action = "zoho:expense:upload-receipt"; domain = "Bookkeeper"; req = @{ uri = $url; method = "POST" }; error = $Detail; ms = $ms } -Domain "Bookkeeper"
        return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
    }
}
