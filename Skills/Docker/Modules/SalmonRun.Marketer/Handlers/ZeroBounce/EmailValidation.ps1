# ZeroBounce.EmailValidation — capability gate for ZeroBounce email validation.
# Required keys: ZEROBOUNCE_API_KEY.
# Capabilities: zerobounce:validate.

$script:ZeroBounceBaseUrl = $env:ZEROBOUNCE_API_BASE_URL ?? "https://api.zerobounce.net/v2"
$script:ZeroBounceUsage = @{ TotalCalls = 0; RateLimited = $false; LastRateLimitAt = $null }
$script:ZeroBounceMaxRetries = 3

function Invoke-ZeroBounceApi {
    [CmdletBinding()]
    param(
        [string]$Method = "GET",
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$QueryParams = @{}
    )

    $QueryParams["api_key"] = $script:ZerobounceApiKey
    $QueryString = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Uri]::EscapeDataString($_.Value))" }) -join "&"
    $Uri = "${script:ZeroBounceBaseUrl}/${Path}?${QueryString}"
    $attempt = 0
    do {
        $attempt++
        try {
            $script:ZeroBounceUsage.TotalCalls++
            $Response = Invoke-ApiCall -Uri $Uri -Method $Method -Domain "marketer" -Action "zerobounce:api" -ReturnRaw
            $StatusCode = [int]$Response.StatusCode
            if ($StatusCode -eq 429 -and $attempt -le $script:ZeroBounceMaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                $script:ZeroBounceUsage.RateLimited = $true
                $script:ZeroBounceUsage.LastRateLimitAt = [datetime]::UtcNow
                Write-MarketerAuditEntry -Capability 'zerobounce:validate' -Action "Invoke-ZeroBounceApi-retry" -Context @{ Path = $Path; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }
            if ($StatusCode -eq 429) {
                $script:ZeroBounceUsage.RateLimited = $true
                $script:ZeroBounceUsage.LastRateLimitAt = [datetime]::UtcNow
                $Detail = try { ($Response.Content | ConvertFrom-Json).error } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                Write-MarketerAuditEntry -Capability 'zerobounce:validate' -Action "Invoke-ZeroBounceApi-rate-limited" -Context @{ Path = $Path; TotalCalls = $script:ZeroBounceUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "ZeroBounce API rate limit hit after $($script:ZeroBounceUsage.TotalCalls) calls: $Detail" }
            }
            if ($StatusCode -ge 400) {
                $Detail = try { ($Response.Content | ConvertFrom-Json).error } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
            }
            $Parsed = $Response.Content | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; Data = $Parsed }
        }
        catch {
            if ($attempt -ge $script:ZeroBounceMaxRetries) {
                return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "ZeroBounce API error - see marketer log for details" }
            }
            Start-Sleep -Milliseconds 1000
        }
    } while ($true)
}

function Invoke-ZeroBounceValidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Email
    )

    Test-MarketerCapability -RequiredCapability 'zerobounce:validate'

    $result = Invoke-ZeroBounceApi -Method GET -Path "validate" -QueryParams @{ email = $Email }
    if ($result.Success) {
        $status = if ($result.Data.status) { $result.Data.status } else { "unknown" }
        Write-MarketerAuditEntry -Capability 'zerobounce:validate' -Action "Invoke-ZeroBounceValidate" -Context @{ Email = $Email; Status = $status } -Result 'allow'
        return [pscustomobject]@{
            Success     = $true
            Email       = $Email
            Status      = $status
            SubStatus   = if ($result.Data.sub_status) { $result.Data.sub_status } else { $null }
            Domain      = if ($result.Data.domain) { $result.Data.domain } else { $null }
            FreeEmail   = if ($null -ne $result.Data.free_email) { [bool]$result.Data.free_email } else { $null }
            Disposable  = if ($null -ne $result.Data.disposable) { [bool]$result.Data.disposable } else { $null }
            CatchAll    = if ($null -ne $result.Data.catch_all) { [bool]$result.Data.catch_all } else { $null }
            MXFound     = if ($null -ne $result.Data.mx_found) { [bool]$result.Data.mx_found } else { $null }
            Account     = if ($result.Data.account) { $result.Data.account } else { $null }
        }
    }
    return $result
}

function Invoke-ZeroBounceBatchValidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Emails
    )

    Test-MarketerCapability -RequiredCapability 'zerobounce:validate'

    $results = @()
    foreach ($email in $Emails) {
        $results += Invoke-ZeroBounceValidate -Email $email
    }

    Write-MarketerAuditEntry -Capability 'zerobounce:validate' -Action "Invoke-ZeroBounceBatchValidate" -Context @{ EmailCount = $Emails.Count } -Result 'allow'
    return [pscustomobject]@{
        Success = $true
        Results = $results
        Count   = $results.Count
    }
}
