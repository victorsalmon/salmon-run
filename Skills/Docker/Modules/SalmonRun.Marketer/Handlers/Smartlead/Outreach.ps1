# Smartlead.Outreach — capability gate for Smartlead campaign and outreach operations.
# Required keys: SMARTLEAD_API_KEY.
# Capabilities: smartlead:campaign.

$script:SmartleadBaseUrl = $env:SMARTLEAD_API_BASE_URL ?? "https://server.smartlead.ai/api/v1"
$script:SmartleadUsage = @{ TotalCalls = 0; RateLimited = $false; LastRateLimitAt = $null }
$script:SmartleadMaxRetries = 3

function Invoke-SmartleadApi {
    [CmdletBinding()]
    param(
        [string]$Method = "GET",
        [Parameter(Mandatory)][string]$Endpoint,
        [hashtable]$QueryParams = @{},
        $Body = $null
    )

    $QueryParams["api_key"] = $script:SmartleadApiKey
    $QueryString = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$([System.Uri]::EscapeDataString($_.Value))" }) -join "&"
    $Uri = "${script:SmartleadBaseUrl}${Endpoint}?${QueryString}"
    $attempt = 0
    do {
        $attempt++
        try {
            $script:SmartleadUsage.TotalCalls++
            $bodyParam = if ($Body) { if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress } } else { $null }
            $Response = Invoke-ApiCall -Uri $Uri -Method $Method -Body $bodyParam -Domain "marketer" -Action "smartlead:outreach" -ReturnRaw
            $StatusCode = [int]$Response.StatusCode
            if ($StatusCode -eq 429 -and $attempt -le $script:SmartleadMaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * 1000
                $script:SmartleadUsage.RateLimited = $true
                $script:SmartleadUsage.LastRateLimitAt = [datetime]::UtcNow
                Write-MarketerAuditEntry -Capability 'smartlead:campaign' -Action "Invoke-SmartleadApi-retry" -Context @{ Endpoint = $Endpoint; Attempt = $attempt; BackoffMs = $backoff } -Result 'deny'
                Start-Sleep -Milliseconds $backoff
                continue
            }
            if ($StatusCode -eq 429) {
                $script:SmartleadUsage.RateLimited = $true
                $script:SmartleadUsage.LastRateLimitAt = [datetime]::UtcNow
                $Detail = try { ($Response.Content | ConvertFrom-Json).message } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                Write-MarketerAuditEntry -Capability 'smartlead:campaign' -Action "Invoke-SmartleadApi-rate-limited" -Context @{ Endpoint = $Endpoint; TotalCalls = $script:SmartleadUsage.TotalCalls } -Result 'deny'
                return [pscustomobject]@{ Success = $false; StatusCode = 429; Message = "Smartlead API rate limit hit after $($script:SmartleadUsage.TotalCalls) calls: $Detail" }
            }
            if ($StatusCode -ge 400) {
                $Detail = try { ($Response.Content | ConvertFrom-Json).message } catch { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) }
                return [pscustomobject]@{ Success = $false; StatusCode = $StatusCode; Message = $Detail }
            }
            $Parsed = $Response.Content | ConvertFrom-Json
            return [pscustomobject]@{ Success = $true; Data = $Parsed }
        }
        catch {
            if ($attempt -ge $script:SmartleadMaxRetries) {
                return [pscustomobject]@{ Success = $false; StatusCode = 500; Message = "Smartlead API error - see marketer log for details" }
            }
            # Exponential backoff on transient transport errors - bounded by $MaxRetries guard above.
            Start-Sleep -Milliseconds ([math]::Pow(2, $attempt) * 500)
        }
    } while ($true)
}

function Invoke-SmartleadCampaign {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CampaignName,
        [Parameter(Mandatory)][string[]]$TargetEmails,
        [string]$FromEmail,
        [string]$Subject,
        [string]$BodyTemplate,
        [int]$DailyLimit = 50
    )

    Test-MarketerCapability -RequiredCapability 'smartlead:campaign'

    $body = @{
        campaign_name = $CampaignName
        target_emails = $TargetEmails
        daily_limit   = $DailyLimit
    }
    if ($FromEmail) { $body.from_email = $FromEmail }
    if ($Subject) { $body.subject = $Subject }
    if ($BodyTemplate) { $body.body = $BodyTemplate }

    $result = Invoke-SmartleadApi -Method POST -Endpoint "/campaigns" -Body $body
    if ($result.Success) {
        Write-MarketerAuditEntry -Capability 'smartlead:campaign' -Action "Invoke-SmartleadCampaign" -Context @{ CampaignName = $CampaignName; TargetCount = $TargetEmails.Count } -Result 'allow'
        return [pscustomobject]@{
            Success      = $true
            CampaignId   = $result.Data.id
            CampaignName = $CampaignName
            TargetCount  = $TargetEmails.Count
        }
    }
    return $result
}
