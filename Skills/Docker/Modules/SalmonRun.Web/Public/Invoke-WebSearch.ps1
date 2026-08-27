<#
.SYNOPSIS
    Performs a web search using the configured backend (Tavily or Firecrawl).
.DESCRIPTION
    Routes the query to Tavily or Firecrawl based on the Backend parameter.
    In auto mode, tries Tavily first and falls back to Firecrawl on failure.
    On 401/403, returns degraded result with Success=$false (no retry).
    Logs each call via Write-WebAuditEntry.
.PARAMETER Query
    The search query string.
.PARAMETER Backend
    Search backend to use: tavily, firecrawl, or auto. Default auto.
.OUTPUTS
    Hashtable with Query, Backend, and Results properties.
#>
function Invoke-WebSearch {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Query,
        [ValidateSet('tavily','firecrawl','auto')][string]$Backend = 'auto'
    )

    $attempts = @()

    if ($Backend -eq 'tavily' -or $Backend -eq 'auto') {
        $result = Invoke-TavilySearch -Query $Query
        if ($result.Success) {
            Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-WebSearch" -Context @{ Query = $Query; Backend = 'tavily'; RemainingQuota = $result.RemainingQuota } -Result 'allow'
            return @{
                Query          = $Query
                Backend        = 'tavily'
                Results        = $result.Results
                RemainingQuota = $result.RemainingQuota
                Success        = $true
            }
        }
        $attempts += @{ Backend = 'tavily'; StatusCode = $result.StatusCode; Message = $result.Message }

        if ($result.StatusCode -eq 429 -or $result.StatusCode -eq 401 -or $result.StatusCode -eq 403) {
            Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-WebSearch-degraded" -Context @{ Query = $Query; StatusCode = $result.StatusCode } -Result 'deny'
            if ($Backend -eq 'tavily') {
                $fireResult = Invoke-FirecrawlSearch -Query $Query
                if ($fireResult.Success) {
                    return @{
                        Query          = $Query
                        Backend        = 'firecrawl'
                        Results        = $fireResult.Results
                        RemainingQuota = $fireResult.RemainingQuota
                        Note           = "Tavily key exhausted ($($result.StatusCode)) — fell back to Firecrawl"
                        Success        = $true
                    }
                }
                $attempts += @{ Backend = 'firecrawl'; StatusCode = $fireResult.StatusCode; Message = $fireResult.Message }
                return @{ Query = $Query; Backend = 'auto'; Error = $fireResult.Message; Success = $false; Attempts = $attempts }
            }
        }
        if ($Backend -eq 'tavily') {
            return @{ Query = $Query; Backend = 'tavily'; Error = $result.Message; Success = $false; StatusCode = $result.StatusCode; Attempts = $attempts }
        }
    }

    if ($Backend -eq 'firecrawl' -or $Backend -eq 'auto') {
        $result = Invoke-FirecrawlSearch -Query $Query
        if ($result.Success) {
            Write-WebAuditEntry -Capability 'search:firecrawl' -Action "Invoke-WebSearch" -Context @{ Query = $Query; Backend = 'firecrawl'; RemainingQuota = $result.RemainingQuota } -Result 'allow'
            return @{
                Query          = $Query
                Backend        = 'firecrawl'
                Results        = $result.Results
                RemainingQuota = $result.RemainingQuota
                Success        = $true
            }
        }
        $attempts += @{ Backend = 'firecrawl'; StatusCode = $result.StatusCode; Message = $result.Message }
        if ($Backend -eq 'firecrawl') {
            return @{ Query = $Query; Backend = 'firecrawl'; Error = $result.Message; Success = $false; StatusCode = $result.StatusCode; Attempts = $attempts }
        }
        return @{ Query = $Query; Backend = 'auto'; Error = $result.Message; Success = $false; StatusCode = $result.StatusCode; Attempts = $attempts }
    }
}
