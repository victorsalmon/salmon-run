# Search.Firecrawl — Firecrawl web search and scraping handler.
# Required keys: FIRECRAWL_API_KEY.
# Capabilities: scrape:firecrawl, search:firecrawl.

$script:FirecrawlApiUrl = "https://api.firecrawl.com/v1/scrape"
$script:FirecrawlSearchApiUrl = "https://api.firecrawl.com/v1/search"

function Invoke-FirecrawlSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 10
    )

    try {
        Test-WebCapability -RequiredCapability 'search:firecrawl'
    } catch [System.UnauthorizedAccessException] {
        if ($_.Exception.Message -like '*Unknown capability*') { throw }
        $script:FirecrawlUsage.KeyExhausted = $true
        $script:FirecrawlUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Firecrawl API key not configured"; Usage = $script:FirecrawlUsage }
    }

    $apiKey = $script:firecrawl_api_key
    if (-not $apiKey) {
        $script:FirecrawlUsage.KeyExhausted = $true
        $script:FirecrawlUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Firecrawl API key not configured"; Usage = $script:FirecrawlUsage }
    }

    $script:FirecrawlUsage.TotalCalls++

    $maxRetries = 3
    $attempt = 0
    do {
        $attempt++
        try {
            $body = @{
                query = $Query
                limit = $MaxResults
            } | ConvertTo-Json -Depth 5 -Compress

            $headers = @{
                Authorization = "Bearer $apiKey"
            }

            $response = Invoke-ApiCall -Uri $script:FirecrawlSearchApiUrl -Method POST -Headers $headers -Body $body -Domain "web" -Action "firecrawl:search" -ReturnRaw

            $parsed = if ($response.Content) {
                $response.Content | ConvertFrom-Json
            } else { $response }

            $data = if ($parsed.data) { $parsed.data } else { @() }

            if ($response.Headers) {
                $remaining = $null
                if ($response.Headers['X-RateLimit-Remaining']) { $remaining = [int]$response.Headers['X-RateLimit-Remaining'] }
                elseif ($response.Headers['RateLimit-Remaining']) { $remaining = [int]$response.Headers['RateLimit-Remaining'] }
                elseif ($response.Headers['x-ratelimit-remaining']) { $remaining = [int]$response.Headers['x-ratelimit-remaining'] }
                $script:FirecrawlUsage.RemainingQuota = $remaining
            }

            Write-WebAuditEntry -Capability 'search:firecrawl' -Action "Invoke-FirecrawlSearch" -Context @{ Query = $Query; ResultCount = @($data).Count; RemainingQuota = $script:FirecrawlUsage.RemainingQuota } -Result 'allow'

            return [pscustomobject]@{
                Success        = $true
                Query          = $Query
                RemainingQuota = $script:FirecrawlUsage.RemainingQuota
                Results        = @($data | ForEach-Object {
                    [pscustomobject]@{
                        Title   = $_.title
                        Url     = $_.url
                        Content = if ($_.description) { $_.description } else { $_.markdown }
                    }
                })
            }
        }
        catch {
            $httpStatus = 500
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $httpStatus = [int]$_.Exception.Response.StatusCode
            }

            if ($httpStatus -eq 429 -and $attempt -le $maxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                Write-WebAuditEntry -Capability 'search:firecrawl' -Action "Invoke-FirecrawlSearch-retry" -Context @{ Query = $Query; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }

            if ($httpStatus -eq 429) {
                $script:FirecrawlUsage.KeyExhausted = $true
                $script:FirecrawlUsage.LastExhaustedAt = [datetime]::UtcNow
                Write-WebAuditEntry -Capability 'search:firecrawl' -Action "Invoke-FirecrawlSearch" -Context @{ Query = $Query; StatusCode = 429; TotalCalls = $script:FirecrawlUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Firecrawl API key exhausted after $($script:FirecrawlUsage.TotalCalls) calls and $($attempt) retries"; Usage = $script:FirecrawlUsage }
            }
            if ($httpStatus -eq 401 -or $httpStatus -eq 403) {
                $script:FirecrawlUsage.KeyExhausted = $true
                Write-WebAuditEntry -Capability 'search:firecrawl' -Action "Invoke-FirecrawlSearch" -Context @{ Query = $Query } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = $httpStatus; Message = "Firecrawl API key rejected ($httpStatus)" }
            }
            Write-WebAuditEntry -Capability 'search:firecrawl' -Action "Invoke-FirecrawlSearch" -Context @{ Query = $Query } -Result 'deny'
            return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Firecrawl search failed: $_" }
        }
    } while ($true)
}

function Invoke-FirecrawlScrape {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Url,
        [string[]]$Formats = @('markdown'),
        [bool]$OnlyMainContent = $true
    )

    if ($Url -notmatch '^https?://') {
        return [pscustomobject]@{ Success = $false; StatusCode = 400; Message = "Invoke-FirecrawlScrape requires an http(s) URL; got: $Url" }
    }

    try {
        Test-WebCapability -RequiredCapability 'scrape:firecrawl'
    } catch [System.UnauthorizedAccessException] {
        if ($_.Exception.Message -like '*Unknown capability*') { throw }
        $script:FirecrawlUsage.KeyExhausted = $true
        $script:FirecrawlUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Firecrawl API key not configured"; Usage = $script:FirecrawlUsage }
    }

    $apiKey = $script:firecrawl_api_key
    if (-not $apiKey) {
        $script:FirecrawlUsage.KeyExhausted = $true
        $script:FirecrawlUsage.TotalCalls++
        return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "Firecrawl API key not configured"; Usage = $script:FirecrawlUsage }
    }

    $script:FirecrawlUsage.TotalCalls++

    $maxRetries = 3
    $attempt = 0
    do {
        $attempt++
        try {
            $body = @{
                url               = $Url
                formats           = $Formats
                onlyMainContent   = $OnlyMainContent
            } | ConvertTo-Json -Depth 5 -Compress

            $headers = @{
                Authorization = "Bearer $apiKey"
            }

            $response = Invoke-ApiCall -Uri $script:FirecrawlApiUrl -Method POST -Headers $headers -Body $body -Domain "web" -Action "firecrawl:scrape" -ReturnRaw

            $parsed = if ($response.Content) {
                $response.Content | ConvertFrom-Json
            } else { $response }

            $data = if ($parsed.data) { $parsed.data } else { $parsed }

            if ($response.Headers) {
                $remaining = $null
                if ($response.Headers['X-RateLimit-Remaining']) { $remaining = [int]$response.Headers['X-RateLimit-Remaining'] }
                elseif ($response.Headers['RateLimit-Remaining']) { $remaining = [int]$response.Headers['RateLimit-Remaining'] }
                elseif ($response.Headers['x-ratelimit-remaining']) { $remaining = [int]$response.Headers['x-ratelimit-remaining'] }
                $script:FirecrawlUsage.RemainingQuota = $remaining
            }

            Write-WebAuditEntry -Capability 'scrape:firecrawl' -Action "Invoke-FirecrawlScrape" -Context @{ Url = $Url; RemainingQuota = $script:FirecrawlUsage.RemainingQuota } -Result 'allow'

            return [pscustomobject]@{
                Success        = $true
                Url            = $Url
                Markdown       = $data.markdown
                Metadata       = if ($data.metadata) { $data.metadata } else { $null }
                RemainingQuota = $script:FirecrawlUsage.RemainingQuota
            }
        }
        catch {
            $httpStatus = 500
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $httpStatus = [int]$_.Exception.Response.StatusCode
            }

            if ($httpStatus -eq 429 -and $attempt -le $maxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                Write-WebAuditEntry -Capability 'scrape:firecrawl' -Action "Invoke-FirecrawlScrape-retry" -Context @{ Url = $Url; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }

            if ($httpStatus -eq 429) {
                $script:FirecrawlUsage.KeyExhausted = $true
                $script:FirecrawlUsage.LastExhaustedAt = [datetime]::UtcNow
                Write-WebAuditEntry -Capability 'scrape:firecrawl' -Action "Invoke-FirecrawlScrape" -Context @{ Url = $Url; StatusCode = 429; TotalCalls = $script:FirecrawlUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Firecrawl API key exhausted after $($script:FirecrawlUsage.TotalCalls) calls and $($attempt) retries"; Usage = $script:FirecrawlUsage }
            }
            if ($httpStatus -eq 401 -or $httpStatus -eq 403) {
                $script:FirecrawlUsage.KeyExhausted = $true
                Write-WebAuditEntry -Capability 'scrape:firecrawl' -Action "Invoke-FirecrawlScrape" -Context @{ Url = $Url } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = $httpStatus; Message = "Firecrawl API key rejected ($httpStatus)" }
            }
            Write-WebAuditEntry -Capability 'scrape:firecrawl' -Action "Invoke-FirecrawlScrape" -Context @{ Url = $Url } -Result 'deny'
            return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Firecrawl scrape failed: $_" }
        }
    } while ($true)
}
