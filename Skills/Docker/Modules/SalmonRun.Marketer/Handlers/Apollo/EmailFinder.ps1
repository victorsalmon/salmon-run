# Apollo.EmailFinder - capability gate for Apollo.io B2B contact lookup and enrichment.
# Required keys: APOLLO_SEARCH, APOLLO_ENRICH.
# Capabilities: apollo:search, apollo:enrich.

$script:ApolloBaseUrl = $env:APOLLO_API_BASE_URL ?? "https://api.apollo.io/api/v1"
$script:ApolloUsage = @{ TotalCalls = 0; RateLimited = $false; LastRateLimitAt = $null }

$script:ApolloMaxRetries = 3

function Invoke-ApolloApi {
    [CmdletBinding()]
    param(
        [string]$Method = "POST",
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$QueryParams = @{},
        $Body = $null
    )

    if (-not $Body) { $Body = @{} }
    $Body.api_key = $script:ApolloSearchKey
    $Uri = "${script:ApolloBaseUrl}/${Path}"
    $attempt = 0
    do {
        $attempt++
        try {
            $script:ApolloUsage.TotalCalls++
            $Response = Invoke-ApiCall -Uri $Uri -Method $Method -Body ($Body | ConvertTo-Json -Depth 10) -Domain "marketer" -Action "apollo:api" -ReturnRaw
            $StatusCode = [int]$Response.StatusCode
            if ($StatusCode -eq 429 -and $attempt -le $script:ApolloMaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                $script:ApolloUsage.RateLimited = $true
                $script:ApolloUsage.LastRateLimitAt = [datetime]::UtcNow
                Write-MarketerAuditEntry -Capability 'apollo:search' -Action "Invoke-ApolloApi-retry" -Context @{ Path = $Path; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }
            if ($StatusCode -eq 429) {
                $script:ApolloUsage.RateLimited = $true
                $script:ApolloUsage.LastRateLimitAt = [datetime]::UtcNow
                $Detail = try { ($Response.Content | ConvertFrom-Json).error } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                Write-MarketerAuditEntry -Capability 'apollo:search' -Action "Invoke-ApolloApi-rate-limited" -Context @{ Path = $Path; TotalCalls = $script:ApolloUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Apollo API rate limit hit after $($script:ApolloUsage.TotalCalls) calls: $Detail" }
            }
            if ($StatusCode -ge 400) {
                $Detail = try { ($Response.Content | ConvertFrom-Json).error } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
            }
            $Parsed = $Response.Content | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; Data = $Parsed }
        }
        catch {
            if ($attempt -ge $script:ApolloMaxRetries) {
                return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Apollo API error - see marketer log for details" }
            }
            # Exponential backoff on transient transport errors - bounded by $MaxRetries guard above.
            Start-Sleep -Milliseconds ([math]::Pow(2, $attempt) * 500)
        }
    } while ($true)
}

function Invoke-ApolloApiEnrich {
    [CmdletBinding()]
    param(
        [string]$Method = "POST",
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )

    if (-not $Body) { $Body = @{} }
    $Body.api_key = $script:ApolloEnrichKey
    $Uri = "${script:ApolloBaseUrl}/${Path}"
    $attempt = 0
    do {
        $attempt++
        try {
            $Response = Invoke-ApiCall -Uri $Uri -Method $Method -Body ($Body | ConvertTo-Json -Depth 10) -Domain "marketer" -Action "apollo:enrich" -ReturnRaw
            $StatusCode = [int]$Response.StatusCode
            if ($StatusCode -eq 429 -and $attempt -le $script:ApolloMaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                Write-MarketerAuditEntry -Capability 'apollo:enrich' -Action "Invoke-ApolloApiEnrich-retry" -Context @{ Path = $Path; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }
            if ($StatusCode -ge 400) {
                $Detail = try { ($Response.Content | ConvertFrom-Json).error } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
            }
            $Parsed = $Response.Content | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; Data = $Parsed }
        }
        catch {
            if ($attempt -ge $script:ApolloMaxRetries) {
                return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Apollo API error - see marketer log for details" }
            }
            # Exponential backoff on transient transport errors - bounded by $MaxRetries guard above.
            Start-Sleep -Milliseconds ([math]::Pow(2, $attempt) * 500)
        }
    } while ($true)
}

function Invoke-ApolloSearch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [string]$Company,
        [string]$FirstName,
        [string]$LastName,
        [string]$Title,
        [int]$Limit = 10
    )

    Test-MarketerCapability -RequiredCapability 'apollo:search'

    $body = @{
        q_organization_domains = @($Domain)
        page                   = 1
        per_page               = $Limit
        person_titles          = @()
    }

    $result = Invoke-ApolloApi -Method POST -Path "people/search" -Body $body
    if ($result.Success) {
        $people = if ($result.Data.people) { $result.Data.people } else { @() }
        if ($people.Count -eq 0) {
            Write-MarketerAuditEntry -Capability 'apollo:search' -Action "Invoke-ApolloSearch-zero" -Context @{ Domain = $Domain } -Result 'deny'
            return [pscustomobject]@{
                Success = $false
                StatusCode = 404
                Message = "Apollo search returned zero results for domain: $Domain"
                People = @()
            }
        }
        Write-MarketerAuditEntry -Capability 'apollo:search' -Action "Invoke-ApolloSearch" -Context @{ Domain = $Domain; ResultCount = $people.Count } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            People = $people | ForEach-Object {
                [pscustomobject]@{
                    PersonId       = $_.id
                    FirstName      = $_.first_name
                    LastName       = $_.last_name
                    Email          = $_.email
                    Title          = $_.title
                    CompanyName    = $_.organization_name
                    Phone          = $_.phone
                    LinkedInUrl    = $_.linkedin_url
                    EmailConfidence = $_.email_confidence
                }
            }
            Pagination = $result.Data.pagination
        }
    }
    return $result
}

function Invoke-ApolloEnrich {
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'Email')][string]$Email,
        [Parameter(ParameterSetName = 'PersonId')][string]$PersonId,
        [string]$Domain
    )

    Test-MarketerCapability -RequiredCapability 'apollo:enrich'

    $body = @{}
    if ($Email) { $body.email = $Email }
    if ($PersonId) { $body.person_id = $PersonId }
    if ($Domain) { $body.organization_domain = $Domain }

    if ($body.Count -eq 0) {
        throw "Either -Email, -PersonId, or -Domain is required"
    }

    $result = Invoke-ApolloApiEnrich -Method POST -Path "people/match" -Body $body
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'apollo:enrich' -Action "Invoke-ApolloEnrich" -Context @{ Email = $Email; PersonId = $PersonId } -Result 'allow'
        $person = $result.Data.person
        return [pscustomobject]@{
            Success = $true
            Person = if ($person) {
                [pscustomobject]@{
                    PersonId        = $person.id
                    FirstName       = $person.first_name
                    LastName        = $person.last_name
                    Email           = $person.email
                    Title           = $person.title
                    CompanyName     = $person.organization_name
                    Phone           = $person.phone
                    LinkedInUrl     = $person.linkedin_url
                    EmailConfidence = $person.email_confidence
                }
            } else { $null }
        }
    }
    return $result
}
