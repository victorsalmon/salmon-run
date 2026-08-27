# Search.Tavily — Tavily search API handler.
# Required keys: TAVILY_API_KEY.
# Capabilities: search:tavily.

$script:TavilyApiUrl = "https://api.tavily.com/search"

function Invoke-TavilySearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 10,
        [string]$SearchDepth = 'basic'
    )

    try {
        Test-WebCapability -RequiredCapability 'search:tavily'
    } catch [System.UnauthorizedAccessException] {
        if ($_.Exception.Message -like '*Unknown capability*') { throw }
        $script:TavilyUsage.KeyExhausted = $true
        $script:TavilyUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Tavily API key not configured"; Usage = $script:TavilyUsage }
    }

    $apiKey = $script:tavily_api_key
    if (-not $apiKey) {
        $script:TavilyUsage.KeyExhausted = $true
        $script:TavilyUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Tavily API key not configured"; Usage = $script:TavilyUsage }
    }

    $script:TavilyUsage.TotalCalls++

    $maxRetries = 3
    $attempt = 0
    do {
        $attempt++
        try {
            $body = @{
                api_key      = $apiKey
                query        = $Query
                max_results  = $MaxResults
                search_depth = $SearchDepth
            } | ConvertTo-Json -Depth 5 -Compress

            $response = Invoke-ApiCall -Uri $script:TavilyApiUrl -Method POST -Body $body -Domain "web" -Action "tavily:search" -ReturnRaw

            $parsed = if ($response.Content) {
                $response.Content | ConvertFrom-Json
            } else { $response }

            $results = if ($parsed.results) { $parsed.results } else { @() }

            if ($response.Headers) {
                $remaining = $null
                if ($response.Headers['X-RateLimit-Remaining']) { $remaining = [int]$response.Headers['X-RateLimit-Remaining'] }
                elseif ($response.Headers['RateLimit-Remaining']) { $remaining = [int]$response.Headers['RateLimit-Remaining'] }
                elseif ($response.Headers['x-ratelimit-remaining']) { $remaining = [int]$response.Headers['x-ratelimit-remaining'] }
                $script:TavilyUsage.RemainingQuota = $remaining
            }

            Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilySearch" -Context @{ Query = $Query; ResultCount = $results.Count; RemainingQuota = $script:TavilyUsage.RemainingQuota } -Result 'allow'

            return [pscustomobject]@{
                Success        = $true
                Query          = $Query
                RemainingQuota = $script:TavilyUsage.RemainingQuota
                Results        = $results | ForEach-Object {
                    [pscustomobject]@{
                        Title       = $_.title
                        Url         = $_.url
                        Content     = $_.content
                        Score       = $_.score
                    }
                }
            }
        }
        catch {
            $httpStatus = 500
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $httpStatus = [int]$_.Exception.Response.StatusCode
            }

            if ($httpStatus -eq 429 -and $attempt -le $maxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilySearch-retry" -Context @{ Query = $Query; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }

            if ($httpStatus -eq 429) {
                $script:TavilyUsage.KeyExhausted = $true
                $script:TavilyUsage.LastExhaustedAt = [datetime]::UtcNow
                Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilySearch" -Context @{ Query = $Query; StatusCode = 429; TotalCalls = $script:TavilyUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Tavily API key exhausted after $($script:TavilyUsage.TotalCalls) calls and $($attempt) retries; try Firecrawl fallback"; Usage = $script:TavilyUsage }
            }
            if ($httpStatus -eq 401 -or $httpStatus -eq 403) {
                $script:TavilyUsage.KeyExhausted = $true
                Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilySearch" -Context @{ Query = $Query } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = $httpStatus; Message = "Tavily API key rejected ($httpStatus); try Firecrawl fallback"; Usage = $script:TavilyUsage }
            }
            Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilySearch" -Context @{ Query = $Query } -Result 'deny'
            return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Tavily search failed: $_" }
        }
    } while ($true)
}

function Invoke-TavilyFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url
    )

    try {
        Test-WebCapability -RequiredCapability 'search:tavily'
    } catch [System.UnauthorizedAccessException] {
        if ($_.Exception.Message -like '*Unknown capability*') { throw }
        $script:TavilyUsage.KeyExhausted = $true
        $script:TavilyUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Tavily API key not configured"; Usage = $script:TavilyUsage }
    }

    $apiKey = $script:tavily_api_key
    if (-not $apiKey) {
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Tavily API key not configured" }
    }

    $script:TavilyUsage.TotalCalls++

    $maxRetries = 3
    $attempt = 0
    do {
        $attempt++
        try {
            $body = @{
                api_key = $apiKey
                url     = $Url
            } | ConvertTo-Json -Depth 5 -Compress

            $response = Invoke-ApiCall -Uri "https://api.tavily.com/extract" -Method POST -Body $body -Domain "web" -Action "tavily:extract" -ReturnRaw

            $parsed = if ($response.Content) {
                $response.Content | ConvertFrom-Json
            } else { $response }

            if ($response.Headers) {
                $remaining = $null
                if ($response.Headers['X-RateLimit-Remaining']) { $remaining = [int]$response.Headers['X-RateLimit-Remaining'] }
                elseif ($response.Headers['RateLimit-Remaining']) { $remaining = [int]$response.Headers['RateLimit-Remaining'] }
                elseif ($response.Headers['x-ratelimit-remaining']) { $remaining = [int]$response.Headers['x-ratelimit-remaining'] }
                $script:TavilyUsage.RemainingQuota = $remaining
            }

            Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilyFetch" -Context @{ Url = $Url; RemainingQuota = $script:TavilyUsage.RemainingQuota } -Result 'allow'

            return [pscustomobject]@{
                Success        = $true
                Url            = $Url
                Content        = $parsed.content
                Title          = $parsed.title
                Images         = if ($parsed.images) { $parsed.images } else { @() }
                RemainingQuota = $script:TavilyUsage.RemainingQuota
            }
        }
        catch {
            $httpStatus = 500
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $httpStatus = [int]$_.Exception.Response.StatusCode
            }

            if ($httpStatus -eq 429 -and $attempt -le $maxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilyFetch-retry" -Context @{ Url = $Url; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }

            if ($httpStatus -eq 429) {
                $script:TavilyUsage.KeyExhausted = $true
                $script:TavilyUsage.LastExhaustedAt = [datetime]::UtcNow
                Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilyFetch" -Context @{ Url = $Url; StatusCode = 429; TotalCalls = $script:TavilyUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Tavily API key exhausted after $($script:TavilyUsage.TotalCalls) calls and $($attempt) retries"; Usage = $script:TavilyUsage }
            }
            if ($httpStatus -eq 401 -or $httpStatus -eq 403) {
                $script:TavilyUsage.KeyExhausted = $true
                Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilyFetch" -Context @{ Url = $Url } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = $httpStatus; Message = "Tavily API key rejected ($httpStatus)" }
            }
            Write-WebAuditEntry -Capability 'search:tavily' -Action "Invoke-TavilyFetch" -Context @{ Url = $Url } -Result 'deny'
            return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Tavily extract failed: $_" }
        }
    } while ($true)
}
