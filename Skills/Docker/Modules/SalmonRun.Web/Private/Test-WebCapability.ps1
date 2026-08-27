<#
.SYNOPSIS
Tests whether a required web capability (e.g. Drive, Tavily) is available.
.PARAMETER RequiredCapability
The capability name to test (e.g. 'search:tavily', 'email:send').
#>
function Test-WebCapability {
    [CmdletBinding()]
    param(
        [string]$RequiredCapability
    )

    $capabilityMap = @{
        'email:send'            = $true
        'search:tavily'         = $script:tavily_api_key
        'scrape:firecrawl'      = $script:firecrawl_api_key
        'search:firecrawl'      = $script:firecrawl_api_key
    }

    if (-not $capabilityMap.ContainsKey($RequiredCapability)) {
        throw [System.UnauthorizedAccessException]::new("Unknown capability: $RequiredCapability")
    }

    if (-not $capabilityMap[$RequiredCapability]) {
        Write-WebAuditEntry -Capability $RequiredCapability -Action "capability-check" -Context @{} -Result 'deny'
        throw [System.UnauthorizedAccessException]::new("Missing required capability: $RequiredCapability. Required secret is not loaded.")
    }

    return $true
}
