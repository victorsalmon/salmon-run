<#
.SYNOPSIS
    Sends a message to the configured Telegram bot owner via the Telegram Bot API.
.DESCRIPTION
    Reads bot config from Get-TelegramConfig, sends a message to the owner's
    chat ID (OwnerUserId). Supports Markdown and HTML parse modes. Logs all
    send attempts to the setup log.
.PARAMETER Message
    The message text to send.
.PARAMETER ParseMode
    Telegram parse mode: MarkdownV2, HTML, or none (default: MarkdownV2).
.PARAMETER Config
    Optional pre-fetched Telegram config hashtable. If omitted, calls Get-TelegramConfig.
.PARAMETER Silent
    Suppress log output (for high-frequency status pings).
.OUTPUTS
    [bool] $true if the message was sent successfully.
#>
function Send-TelegramMessage {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('MarkdownV2', 'HTML', 'none')]
        [string]$ParseMode = 'MarkdownV2',

        [Parameter()]
        [hashtable]$Config,

        [Parameter()]
        [switch]$Silent
    )

    if (-not $Config) {
        $Config = Get-TelegramConfig
    }

    if (-not $Config.IsConfigured) {
        if (-not $Silent) {
            Write-SetupLog "[TELEGRAM SEND] Cannot send — Telegram not configured" -Level WARN
        }
        return $false
    }

    $apiUrl = "https://api.telegram.org/bot$($Config.BotToken)/sendMessage"
    $body = @{
        chat_id                  = $Config.OwnerUserId
        text                     = $Message
        disable_web_page_preview = $true
    }

    if ($ParseMode -ne 'none') {
        $body.parse_mode = $ParseMode
    }

    try {
        $jsonBody = $body | ConvertTo-Json
        $response = Invoke-WebRequest -Uri $apiUrl -Method POST `
            -Body $jsonBody -ContentType 'application/json' `
            -TimeoutSec 15 -ErrorAction Stop

        if ($response.StatusCode -eq 200) {
            $result = $response.Content | ConvertFrom-Json
            if ($result.ok) {
                if (-not $Silent) {
                    Write-SetupLog "[TELEGRAM SEND] Message sent to $($Config.OwnerUsername) (chat $($Config.OwnerUserId))" -Level INFO
                }
                return $true
            }
        }

        if (-not $Silent) {
            Write-SetupLog "[TELEGRAM SEND] API returned non-OK status: $($response.StatusCode)" -Level WARN
        }
        return $false
    } catch {
        if (-not $Silent) {
            Write-SetupLog "[TELEGRAM SEND] Failed: $_" -Level WARN
        }
        return $false
    }
}
