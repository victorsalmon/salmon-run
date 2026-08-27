<#
.SYNOPSIS
    Polls the Telegram Bot API for incoming messages and writes them as task stubs.
.DESCRIPTION
    Uses getUpdates to poll for new messages from authorized senders. Writes
    each message as a markdown task stub in a configurable output directory
    (default: Tasks/Telegram/). Tracks the last seen update_id via an offset
    file to avoid re-processing. Only processes messages from the configured
    owner (validated via Test-TelegramSender).
.PARAMETER OutputDir
    Directory to write incoming message task stubs (default: repo-root/Tasks/Telegram/).
.PARAMETER OffsetFile
    Path to the update_id offset file (default: repo-root/Tasks/Logs/telegram-offset.txt).
.PARAMETER Config
    Optional pre-fetched Telegram config hashtable.
.PARAMETER TimeoutSec
    Long-polling timeout in seconds (default: 30).
.OUTPUTS
    [int] Number of new messages processed.
#>
function Receive-TelegramMessages {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$OutputDir,
        [string]$OffsetFile,
        [hashtable]$Config,
        [int]$TimeoutSec = 30
    )

    if (-not $Config) {
        $Config = Get-TelegramConfig
    }

    if (-not $Config.IsConfigured) {
        Write-SetupLog "[TELEGRAM RECV] Cannot poll — Telegram not configured" -Level WARN
        return 0
    }

    # Resolve default paths relative to repo root
    if (-not $OutputDir -or -not (Test-Path $OutputDir)) {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')
        if (-not $OutputDir) {
            $OutputDir = Join-Path $repoRoot 'Tasks\Telegram'
        }
        if (-not $OffsetFile) {
            $OffsetFile = Join-Path $repoRoot 'Tasks\Logs\telegram-offset.txt'
        }
    }

    # Ensure output dir exists
    $null = New-Item -ItemType Directory -Path $OutputDir -Force

    # Read last seen update_id
    $offset = 0
    if ($OffsetFile -and (Test-Path $OffsetFile)) {
        $content = (Get-Content $OffsetFile -Raw -ErrorAction SilentlyContinue)?.Trim()
        if ($content -match '^\d+$') {
            $offset = [int]$content
        }
    }

    $apiUrl = "https://api.telegram.org/bot$($Config.BotToken)/getUpdates"
    $body = @{
        offset   = $offset
        timeout  = $TimeoutSec
        allowed_updates = @('message')
    }

    $processedCount = 0

    try {
        $jsonBody = $body | ConvertTo-Json
        $response = Invoke-WebRequest -Uri $apiUrl -Method POST `
            -Body $jsonBody -ContentType 'application/json' `
            -TimeoutSec ($TimeoutSec + 10) -ErrorAction Stop

        if ($response.StatusCode -ne 200) {
            Write-SetupLog "[TELEGRAM RECV] API returned status $($response.StatusCode)" -Level WARN
            return 0
        }

        $result = $response.Content | ConvertFrom-Json
        if (-not $result.ok -or -not $result.result) {
            return 0
        }

        $maxUpdateId = $offset

        foreach ($update in $result.result) {
            if ($update.update_id -gt $maxUpdateId) {
                $maxUpdateId = $update.update_id
            }

            # Skip non-message updates
            if (-not $update.message) { continue }

            $msg = $update.message
            $fromUsername = $msg.from.username ?? ''
            $fromUserId = [string]$msg.from.id
            $text = ($msg.text ?? $msg.caption ?? '').Trim()

            # Skip empty messages
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            # Validate sender
            $auth = Test-TelegramSender -FromUsername $fromUsername -FromUserId $fromUserId -Config $Config
            if (-not $auth.IsAuthorized) {
                Write-TelegramSecurityEvent -EventType 'UNAUTHORIZED_MESSAGE' `
                    -SenderUsername $fromUsername -SenderUserId $fromUserId `
                    -MessageText $text -Detail $auth.RejectionReason
                continue
            }

            # Write incoming message as task stub
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $safeSender = ($fromUsername -replace '[^a-zA-Z0-9_-]', '') -replace '^@', ''
            $msgId = $msg.message_id
            $taskFile = Join-Path $OutputDir "telegram-$timestamp-$msgId.md"

            $taskContent = @"
---
source: telegram
sender: @$fromUsername
sender_id: $fromUserId
message_id: $msgId
received_at: $(Get-Date -Format 'o')
status: ready
---

# Telegram Message from @$fromUsername

$text

## Instructions
Process this incoming message as a prompt/command. Implement what was requested.
If this is a question, answer it. If it is a task, implement it.

---

**Status**: ready
**Assigned**: coder
"@

            $taskContent | Out-File $taskFile -Encoding utf8
            $processedCount++

            Write-SetupLog "[TELEGRAM RECV] Message $msgId from @$fromUsername — written to $taskFile" -Level INFO
        }

        # Persist the highest seen update_id
        if ($maxUpdateId -gt $offset -and $OffsetFile) {
            $offsetDir = Split-Path $OffsetFile -Parent
            $null = New-Item -ItemType Directory -Path $offsetDir -Force
            $maxUpdateId | Out-File $OffsetFile -Encoding utf8
        }

    } catch {
        Write-SetupLog "[TELEGRAM RECV] Poll failed: $_" -Level WARN
    }

    return $processedCount
}
