# Interclaw Telegram Security Module
# Provides sender validation, security event logging, and anomaly detection
# for the Telegram bot channel. Enforces strict owner-only access.

# Telegram Bot API version pinned for all API calls
# See https://core.telegram.org/bots/api for changelog
$script:TelegramBotApiVersion = "8.2"

function Assert-TelegramApiVersion {
    <#
    .SYNOPSIS
        Validates that the Telegram Bot API version is supported by checking
        the getMe endpoint with the pinned version parameter.
    .OUTPUTS
        [bool] $true if the API version is reachable, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BotToken
    )

    $apiUrl = "https://api.telegram.org/bot${BotToken}/getMe?api_version=$($script:TelegramBotApiVersion)"
    try {
        $response = Invoke-WebRequest -Uri $apiUrl -Method GET -TimeoutSec 10 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            $body = $response.Content | ConvertFrom-Json
            if ($body.ok) {
                Write-SetupLog "[TELEGRAM] Bot API version $($script:TelegramBotApiVersion) confirmed — bot '@($body.result.username)' is reachable" -Level INFO
                return $true
            }
        }
        Write-SetupLog "[TELEGRAM] Bot API version $($script:TelegramBotApiVersion) check returned non-OK status" -Level WARN
        return $false
    } catch {
        Write-SetupLog "[TELEGRAM] Bot API version $($script:TelegramBotApiVersion) check failed: $_" -Level WARN
        return $false
    }
}

function Get-TelegramConfig {
    <#
    .SYNOPSIS
        Reads Telegram configuration from Docker secrets and environment variables.
    .OUTPUTS
        Hashtable with BotToken, OwnerUsername, OwnerUserId, and security flags.
    #>
    [CmdletBinding()]
    param()

    $Config = @{
        BotToken         = $null
        OwnerUsername    = $null
        OwnerUserId      = $null
        IsConfigured     = $false
    }

    # Priority 1: Docker Swarm secrets (production)
    $TokenPath = "/run/secrets/telegram_bot_token_orch"
    if (Test-Path $TokenPath -PathType Leaf) {
        $Config.BotToken = (Get-Content $TokenPath -Raw).Trim()
    }

    $OwnerUserPath = "/run/secrets/telegram_owner_username"
    if (Test-Path $OwnerUserPath -PathType Leaf) {
        $Config.OwnerUsername = (Get-Content $OwnerUserPath -Raw).Trim()
    }

    $OwnerIdPath = "/run/secrets/telegram_owner_userid"
    if (Test-Path $OwnerIdPath -PathType Leaf) {
        $Config.OwnerUserId = (Get-Content $OwnerIdPath -Raw).Trim()
    }

    # Priority 2: Environment variables (fallback for local dev)
    if ([string]::IsNullOrWhiteSpace($Config.BotToken) -and $env:TELEGRAM_BOT_TOKEN_ORCH) {
        $Config.BotToken = $env:TELEGRAM_BOT_TOKEN_ORCH
    }
    if ([string]::IsNullOrWhiteSpace($Config.OwnerUsername) -and $env:TELEGRAM_OWNER_USERNAME) {
        $Config.OwnerUsername = $env:TELEGRAM_OWNER_USERNAME
    }
    if ([string]::IsNullOrWhiteSpace($Config.OwnerUserId) -and $env:TELEGRAM_OWNER_USERID) {
        $Config.OwnerUserId = $env:TELEGRAM_OWNER_USERID
    }

    # Validate configuration completeness
    $Config.IsConfigured = -not [string]::IsNullOrWhiteSpace($Config.BotToken) -and
                           -not [string]::IsNullOrWhiteSpace($Config.OwnerUsername) -and
                           -not [string]::IsNullOrWhiteSpace($Config.OwnerUserId)

    return $Config
}

function Test-TelegramSender {
    <#
    .SYNOPSIS
        Validates an incoming Telegram message sender against the owner whitelist.
        Returns detailed result object for explicit error logging.
    .PARAMETER FromUsername
        The sender's Telegram username (without @ prefix).
    .PARAMETER FromUserId
        The sender's numeric Telegram user ID.
    .PARAMETER Config
        Telegram configuration hashtable from Get-TelegramConfig.
    .OUTPUTS
        PSCustomObject with IsAuthorized, RejectionReason, and Detail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FromUsername,

        [Parameter(Mandatory = $true)]
        [string]$FromUserId,

        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $Result = [PSCustomObject]@{
        IsAuthorized    = $false
        RejectionReason = $null
        Detail          = $null
        Timestamp       = Get-Date -Format "o"
    }

    if (-not $Config.IsConfigured) {
        $Result.RejectionReason = "TELEGRAM_NOT_CONFIGURED"
        $Result.Detail = "Telegram owner credentials are not configured in secrets. Check telegram_bot_token_orch, telegram_owner_username, and telegram_owner_userid."
        Write-SetupLog "[TELEGRAM SECURITY] Blocked message: Telegram not configured. Sender='${FromUsername}' ID='${FromUserId}'" -Level ERROR
        return $Result
    }

    # Normalize username (remove @ if present)
    $NormalizedUsername = $FromUsername -replace '^@', ''
    $NormalizedOwner = $Config.OwnerUsername -replace '^@', ''

    # Check username match
    $UsernameMatch = $NormalizedUsername -eq $NormalizedOwner

    # Check user ID match
    $UserIdMatch = $FromUserId -eq $Config.OwnerUserId

    if ($UsernameMatch -and $UserIdMatch) {
        $Result.IsAuthorized = $true
        $Result.Detail = "Sender verified by both username and user ID."
        return $Result
    }

    if (-not $UsernameMatch -and -not $UserIdMatch) {
        $Result.RejectionReason = "BOTH_MISMATCH"
        $Result.Detail = "Username '${NormalizedUsername}' does not match owner '${NormalizedOwner}' AND user ID '${FromUserId}' does not match owner ID '${Config.OwnerUserId}'."
    }
    elseif (-not $UsernameMatch) {
        $Result.RejectionReason = "USERNAME_MISMATCH"
        $Result.Detail = "Username '${NormalizedUsername}' does not match owner '${NormalizedOwner}'. User ID matched but username did not."
    }
    else {
        $Result.RejectionReason = "USERID_MISMATCH"
        $Result.Detail = "User ID '${FromUserId}' does not match owner ID '${Config.OwnerUserId}'. Username matched but user ID did not."
    }

    Write-SetupLog "[TELEGRAM SECURITY] Blocked unauthorized message. Reason=$($Result.RejectionReason) Sender='${NormalizedUsername}' ID='${FromUserId}' ExpectedUser='${NormalizedOwner}' ExpectedId='${Config.OwnerUserId}'" -Level WARN
    return $Result
}

function Write-TelegramSecurityEvent {
    <#
    .SYNOPSIS
        Logs a Telegram security event to the security audit log.
        Non-owner messages are logged silently (no notifications).
    .PARAMETER EventType
        Type of security event: UNAUTHORIZED_MESSAGE, HIGH_VOLUME, PROMPT_INJECTION_ATTEMPT, CONFIG_ERROR.
    .PARAMETER SenderUsername
        The sender's Telegram username.
    .PARAMETER SenderUserId
        The sender's numeric user ID.
    .PARAMETER MessageText
        The message content (truncated for safety).
    .PARAMETER Detail
        Additional context about the event.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("UNAUTHORIZED_MESSAGE","HIGH_VOLUME","PROMPT_INJECTION_ATTEMPT","CONFIG_ERROR")]
        [string]$EventType,

        [string]$SenderUsername = "unknown",
        [string]$SenderUserId = "unknown",
        [string]$MessageText = "",
        [string]$Detail = ""
    )

    $LogDir = Join-Path (Get-ReportsDir) "security"
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $LogFile = Join-Path $LogDir "telegram-security-$(Get-Date -Format 'yyyyMMdd').log"
    $Timestamp = Get-Date -Format "o"

    # Truncate message text to prevent log flooding
    $TruncatedText = if ($MessageText.Length -gt 200) { $MessageText.Substring(0, 200) + "...[truncated]" } else { $MessageText }

    $LogEntry = @{
        timestamp      = $Timestamp
        eventType      = $EventType
        senderUsername = $SenderUsername
        senderUserId   = $SenderUserId
        messagePreview = $TruncatedText
        detail         = $Detail
    } | ConvertTo-Json -Compress

    Add-Content -Path $LogFile -Value $LogEntry -Encoding UTF8 -ErrorAction SilentlyContinue

    # Also write to main setup log for immediate visibility of serious events
    if ($EventType -in @("HIGH_VOLUME", "PROMPT_INJECTION_ATTEMPT", "CONFIG_ERROR")) {
        Write-SetupLog "[TELEGRAM SECURITY] $EventType from user='${SenderUsername}' id='${SenderUserId}'. Detail: $Detail" -Level WARN
    }
}

function Test-TelegramTrafficAnomaly {
    <#
    .SYNOPSIS
        Analyzes Telegram security logs for high-volume unauthorized traffic.
        Returns $true if an anomaly is detected (more than threshold events in window).
    .PARAMETER Threshold
        Number of unauthorized events to trigger anomaly detection. Default: 10.
    .PARAMETER WindowMinutes
        Time window in minutes to analyze. Default: 5.
    .OUTPUTS
        PSCustomObject with IsAnomaly, EventCount, and Recommendation.
    #>
    [CmdletBinding()]
    param(
        [int]$Threshold = 10,
        [int]$WindowMinutes = 5
    )

    $Result = [PSCustomObject]@{
        IsAnomaly       = $false
        EventCount      = 0
        WindowStart     = $null
        Recommendation  = $null
    }

    $LogDir = Join-Path (Get-ReportsDir) "security"
    $TodayFile = Join-Path $LogDir "telegram-security-$(Get-Date -Format 'yyyyMMdd').log"

    if (-not (Test-Path $TodayFile)) {
        return $Result
    }

    $Cutoff = [DateTime]::UtcNow.AddMinutes(-$WindowMinutes)
    $Result.WindowStart = $Cutoff.ToString("o")

    $Events = Get-Content $TodayFile -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_ | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { $null }
    } | Where-Object {
        $_ -and $_.eventType -eq "UNAUTHORIZED_MESSAGE" -and [datetime]$_.timestamp -gt $Cutoff
    }

    $Result.EventCount = ($Events | Measure-Object).Count

    if ($Result.EventCount -ge $Threshold) {
        $Result.IsAnomaly = $true
        $UniqueSenders = ($Events | Select-Object -ExpandProperty senderUserId -Unique | Measure-Object).Count
        $Result.Recommendation = "Detected $Result.EventCount unauthorized Telegram messages in ${WindowMinutes} minutes from $UniqueSenders unique sender(s). Consider reviewing firewall rules or revoking the bot token if under attack."
        Write-SetupLog "[TELEGRAM ANOMALY] $($Result.Recommendation)" -Level WARN
        Write-TelegramSecurityEvent -EventType "HIGH_VOLUME" -Detail $Result.Recommendation
    }

    return $Result
}
