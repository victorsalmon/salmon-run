<#
.SYNOPSIS
Tests whether a required Bookkeeper capability (e.g. Zoho expense access) is available.
.PARAMETER RequiredCapability
The capability name to test (e.g. 'zoho:expense:read').
#>
function Test-BookkeepingCapability {
    [CmdletBinding()]
    param(
        [string]$RequiredCapability
    )

    $capabilityMap = @{
        'zoho:expense:read'        = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:expense:write'       = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:expense:attach'      = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:bankaccount:read'    = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:chartofaccount:read' = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:report:read'         = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:chartofaccount:write' = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:contact:read'        = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:contact:write'       = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:invoice:read'        = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:invoice:write'       = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:banktransaction:write' = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:transfer:read'        = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'zoho:transfer:write'       = $script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken
        'vision:ocr'               = [bool]$script:OpenRouterApiKey
        'plaid:sync'               = $true
    }

    if (-not $capabilityMap.ContainsKey($RequiredCapability)) {
        Write-Warning "Test-BookkeepingCapability: Unknown capability '$RequiredCapability'"
        throw "Unknown capability '$RequiredCapability' — not registered in capability map"
    }

    if (-not $capabilityMap[$RequiredCapability]) {
        Write-Warning "Test-BookkeepingCapability: Missing required capability '$RequiredCapability' — credentials not loaded"
        Write-BookkeepingAuditEntry -Capability $RequiredCapability -Action "capability-check" -Context @{} -Result 'deny'
        throw "Missing required capability '$RequiredCapability' — credentials not loaded in this environment"
    }

    # Capability is present. Intentionally emit nothing on the success path —
    # callers invoke this as a guard (Test-...) and any successful output would
    # leak into the caller's return pipeline, causing arrays where scalars are
    # expected. Use [bool](Test-BookkeepingCapability ...) if you need the value.
}
