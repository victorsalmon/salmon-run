# Hunter.EmailFinder — capability gate for Hunter.io email finding and verification.
# Required keys: HUNTER_API_KEY.
# Capabilities: hunter:search.

$script:HunterBaseUrl = $env:HUNTER_API_BASE_URL ?? "https://api.hunter.io/v2"
$script:HunterUsage = @{ TotalCalls = 0; RateLimited = $false; LastRateLimitAt = $null }
$script:HunterMaxRetries = 3

function Invoke-HunterApi {
    [CmdletBinding()]
    param(
        [string]$Method = "GET",
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$QueryParams = @{},
        $Body = $null
    )

    $QueryParams["api_key"] = $script:HunterApiKey
    $QueryString = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Uri]::EscapeDataString($_.Value))" }) -join "&"
    $Uri = "${script:HunterBaseUrl}/${Path}?${QueryString}"
    $attempt = 0
    do {
        $attempt++
        try {
            $script:HunterUsage.TotalCalls++
            $Response = Invoke-ApiCall -Uri $Uri -Method $Method -Body $Body -Domain "marketer" -Action "hunter:email-find" -ReturnRaw
            $StatusCode = [int]$Response.StatusCode
            if ($StatusCode -eq 429 -and $attempt -le $script:HunterMaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                $script:HunterUsage.RateLimited = $true
                $script:HunterUsage.LastRateLimitAt = [datetime]::UtcNow
                Write-MarketerAuditEntry -Capability 'hunter:search' -Action "Invoke-HunterApi-retry" -Context @{ Path = $Path; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }
            if ($StatusCode -eq 429) {
                $script:HunterUsage.RateLimited = $true
                $script:HunterUsage.LastRateLimitAt = [datetime]::UtcNow
                $Detail = try { ($Response.Content | ConvertFrom-Json).errors[0].detail } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                Write-MarketerAuditEntry -Capability 'hunter:search' -Action "Invoke-HunterApi-rate-limited" -Context @{ Path = $Path; TotalCalls = $script:HunterUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Hunter API rate limit hit after $($script:HunterUsage.TotalCalls) calls: $Detail" }
            }
            if ($StatusCode -ge 400) {
                $Detail = try { ($Response.Content | ConvertFrom-Json).errors[0].detail } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
            }
            $Parsed = $Response.Content | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; Data = $Parsed }
        }
        catch {
            if ($attempt -ge $script:HunterMaxRetries) {
                return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Hunter API error - see marketer log for details" }
            }
            # Exponential backoff on transient transport errors - bounded by $MaxRetries guard above.
            Start-Sleep -Milliseconds ([math]::Pow(2, $attempt) * 500)
        }
    } while ($true)
}

function Invoke-HunterSearch {
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'Domain')][string]$Domain,
        [Parameter(ParameterSetName = 'Email')][string]$Email,
        [string]$Company,
        [string]$FirstName,
        [string]$LastName,
        [int]$Limit = 10
    )

    Test-MarketerCapability -RequiredCapability 'hunter:search'

    $queryParams = @{}

    if ($PSCmdlet.ParameterSetName -eq 'Domain') {
        $queryParams["domain"] = $Domain
        $Path = "domain-search"
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Email') {
        $queryParams["email"] = $Email
        $Path = "email-finder"
    }
    else {
        throw "Either -Domain or -Email is required"
    }

    if ($Company) { $queryParams["company"] = $Company }
    if ($FirstName) { $queryParams["first_name"] = $FirstName }
    if ($LastName) { $queryParams["last_name"] = $LastName }
    $queryParams["limit"] = $Limit

    $result = Invoke-HunterApi -Method GET -Path $Path -QueryParams $queryParams
    if ($result.Success) {
        $emails = if ($result.Data.data.emails) { $result.Data.data.emails } else { @() }
        if ($emails.Count -eq 0) {
            Write-MarketerAuditEntry -Capability 'hunter:search' -Action "Invoke-HunterSearch-zero" -Context @{ Domain = $Domain; Email = $Email } -Result 'deny'
            return [pscustomobject]@{
                Success = $false
                StatusCode = 404
                Message = "Hunter search returned zero results for domain: $Domain"
                Emails = @()
            }
        }
        Write-MarketerAuditEntry -Capability 'hunter:search' -Action "Invoke-HunterSearch" -Context @{ Domain = $Domain; Email = $Email; ResultCount = $emails.Count } -Result 'allow'
        return [pscustomobject]@{
            Success = $true
            Emails = $emails | ForEach-Object {
                [pscustomobject]@{
                    Email      = $_.value
                    FirstName  = $_.first_name
                    LastName   = $_.last_name
                    Position   = $_.position
                    Seniority  = $_.seniority
                    Department = $_.department
                    Confidence = $_.confidence
                }
            }
            Meta = $result.Data.meta
        }
    }
    return $result
}
