# Attio.Persons — capability gate for contact (person) operations.
# Required keys: ATTIO_WRITE_KEY, ATTIO_READ_KEY, ATTIO_ARCHIVE_KEY.
# Capabilities: attio:read, attio:write, attio:archive.

$script:AttioUsage = @{ TotalCalls = 0; RateLimited = $false; LastRateLimitAt = $null }

$script:AttioMaxRetries = 3

function Invoke-AttioApi {
    param($Method, $Endpoint, $Body = "", $ApiKey)
    $BaseUrl = "https://api.attio.com/v2"
    $Uri = "${BaseUrl}${Endpoint}"
    $Headers = @{ Authorization = "Bearer $ApiKey" }
    $attempt = 0
    do {
        $attempt++
        try {
            $script:AttioUsage.TotalCalls++
            $WebResponse = Invoke-ApiCall -Uri $Uri -Method $Method -Headers $Headers -Body $Body -Domain "marketer" -Action "attio:api" -ReturnRaw
            $StatusCode = [int]$WebResponse.StatusCode

            if ($StatusCode -eq 429 -and $attempt -le $script:AttioMaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                $script:AttioUsage.RateLimited = $true
                $script:AttioUsage.LastRateLimitAt = [datetime]::UtcNow
                Write-MarketerAuditEntry -Capability 'attio:api' -Action "Invoke-AttioApi-retry" -Context @{ Endpoint = $Endpoint; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }

            if ($StatusCode -eq 429) {
                Write-MarketerAuditEntry -Capability 'attio:api' -Action "Invoke-AttioApi-rate-limited" -Context @{ Endpoint = $Endpoint; StatusCode = 429; TotalCalls = $script:AttioUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Attio API rate limit hit after $($script:AttioUsage.TotalCalls) calls and $($attempt) retries" }
            }
            if ($StatusCode -ge 400) {
                $Detail = $WebResponse.Content
                Write-MarketerAuditEntry -Capability 'attio:api' -Action "Invoke-AttioApi-error" -Context @{ Endpoint = $Endpoint; StatusCode = $StatusCode } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
            }
            $Parsed = $WebResponse.Content | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; Data = $Parsed }
        }
        catch {
            if ($attempt -ge $script:AttioMaxRetries) {
                return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "API error - see marketer log for details" }
            }
            # Exponential backoff on transient transport errors - bounded by $MaxRetries guard above.
            Start-Sleep -Milliseconds ([math]::Pow(2, $attempt) * 500)
        }
    } while ($true)
}

function Get-AttioPerson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PersonId
    )

    Test-MarketerCapability -RequiredCapability 'attio:read'

    $result = Invoke-AttioApi -Method GET -Endpoint "/objects/people/records/$PersonId" -ApiKey $script:AttioReadKey
    if ($result.Success -and $result.Data.data) {
        $p = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:read' -Action "Get-AttioPerson" -Context @{ PersonId = $PersonId } -Result 'allow'
        return [pscustomobject]@{
            PersonId     = $p.id.record_id
            DisplayName  = $p.values.name_components
            EmailAddress = $p.values.email_addresses
            CompanyName  = $p.values.current_employer
        }
    }
    if ($result.Success -and -not $result.Data.data) {
        Write-MarketerAuditEntry -Capability 'attio:read' -Action "Get-AttioPerson-not-found" -Context @{ PersonId = $PersonId } -Result 'deny'
        return [pscustomobject]@{ Success = $false; StatusCode = 404; Message = "Person not found: $PersonId" }
    }
    return $result
}

function New-AttioPerson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$EmailAddress,
        [string]$CompanyName
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $body = @{
        data = @{
            values = @{
                name_components = @(@{ value = $DisplayName })
                email_addresses = @(@{ primary = $true; email_address = $EmailAddress })
            }
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $result = Invoke-AttioApi -Method POST -Endpoint "/objects/people/records" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success -and $result.Data.data) {
        $p = $result.Data.data
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "New-AttioPerson" -Context @{ Email = $EmailAddress } -Result 'allow'
        return [pscustomobject]@{
            PersonId     = $p.id.record_id
            DisplayName  = $DisplayName
            EmailAddress = $EmailAddress
            CompanyName  = $CompanyName
        }
    }
    return $result
}

function Update-AttioPerson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PersonId,
        [string]$DisplayName,
        [string]$EmailAddress,
        [string]$CompanyName
    )

    Test-MarketerCapability -RequiredCapability 'attio:write'

    $values = @{}
    if ($DisplayName) { $values.name_components = @(@{ value = $DisplayName }) }
    if ($EmailAddress) { $values.email_addresses = @(@{ primary = $true; email_address = $EmailAddress }) }

    $body = @{ data = @{ values = $values } } | ConvertTo-Json -Depth 5 -Compress
    $result = Invoke-AttioApi -Method PATCH -Endpoint "/objects/people/records/$PersonId" -Body $body -ApiKey $script:AttioWriteKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:write' -Action "Update-AttioPerson" -Context @{ PersonId = $PersonId } -Result 'allow'
    }
    return $result
}

function Archive-AttioPerson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PersonId
    )

    Test-MarketerCapability -RequiredCapability 'attio:archive'

    $body = @{
        data = @{
            values = @{
                lifecycle_stage = @(@{
                    active_from   = (Get-Date -Format 'o')
                    active_option = "archived"
                })
            }
        }
    } | ConvertTo-Json -Depth 5

    $result = Invoke-AttioApi -Method PATCH -Endpoint "/objects/people/records/$PersonId" -Body $body -ApiKey $script:AttioArchiveKey
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'attio:archive' -Action "Archive-AttioPerson" -Context @{ PersonId = $PersonId } -Result 'allow'
    }
    return $result
}
