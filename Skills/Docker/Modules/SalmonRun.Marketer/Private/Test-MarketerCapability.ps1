<#
.SYNOPSIS
Tests whether a required marketer capability (e.g. Attio, Hunter) is available.
.PARAMETER RequiredCapability
The capability name to test (e.g. 'attio:read', 'hunter:search').
#>
function Test-MarketerCapability {
    [CmdletBinding()]
    param(
        [string]$RequiredCapability
    )

    $capabilityMap = @{
        'attio:read'          = [bool]$script:AttioReadKey
        'attio:write'         = [bool]$script:AttioWriteKey
        'attio:archive'       = [bool]$script:AttioArchiveKey
        'hunter:search'       = [bool]$script:HunterApiKey
        'apollo:search'       = [bool]$script:ApolloSearchKey
        'apollo:enrich'       = [bool]$script:ApolloEnrichKey
        'smartlead:campaign'  = [bool]$script:SmartleadApiKey
        'zerobounce:validate' = [bool]$script:ZerobounceApiKey
        'onboarding:create'   = $true
        'analysis:run'        = [bool]$script:OpenrouterApiKey
    }

    if (-not $capabilityMap.ContainsKey($RequiredCapability)) {
        throw [System.UnauthorizedAccessException]::new("Unknown capability: $RequiredCapability")
    }

    if (-not $capabilityMap[$RequiredCapability]) {
        Write-MarketerAuditEntry -Capability $RequiredCapability -Action "capability-check" -Context @{} -Result 'deny'
        throw [System.UnauthorizedAccessException]::new("Missing required capability: $RequiredCapability. Required secret is not loaded.")
    }

    return $true
}
