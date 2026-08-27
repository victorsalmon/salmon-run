# Zoho.Auth — shared OAuth token management, token lock, and rate-limit circuit breaker.
# Dot-sourced by SalmonRun.Bookkeeping.psm1 before all handler files.
# All handlers share $script: scoped state from this file.
# Required keys: ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH.

$script:ZohoBaseUrl = "https://www.zohoapis.com/books/v3"
$script:ZohoAccountsUrl = "https://accounts.zoho.com/oauth/v2/token"
$script:ZohoAccessTokenExpiry = $null
$script:ZohoAccessTokenValue = $null
$script:ZohoMaxRetries = 5
$script:ZohoRetryBaseDelayMs = 2000
$script:ZohoRetryStatusCodes = @(429, 502, 503, 504)
$script:ZohoTokenLockPath = "/tmp/zoho-token.lock"
$script:ZohoCircuitBreakerExpiry = $null
$script:ZohoTokenCachePath = "/app/zoho-token-cache.json"

function Load-ZohoTokenCache {
    if (-not (Test-Path $script:ZohoTokenCachePath)) { return }
    try {
        $cached = Get-Content -LiteralPath $script:ZohoTokenCachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $expiry = if ($cached.expires_at -is [datetime]) { $cached.expires_at } else { [datetime]::ParseExact($cached.expires_at, 'o', $null) }
        if ($expiry -gt [datetime]::UtcNow.AddMinutes(5)) {
            $script:ZohoAccessTokenValue = $cached.access_token
            $script:ZohoAccessTokenExpiry = $expiry
            Write-Debug "Load-ZohoTokenCache: Loaded cached token, expires at $expiry"
        }
    } catch {
        Write-Debug "Load-ZohoTokenCache: Failed to load cache: $_"
    }
}

function Save-ZohoTokenCache {
    param([string]$Token, [datetime]$Expiry)
    try {
        $cache = @{
            access_token = $Token
            expires_at   = $Expiry.ToString('o')
            cached_at    = [datetime]::UtcNow.ToString('o')
        }
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($script:ZohoTokenCachePath, ($cache | ConvertTo-Json -Compress), $utf8NoBom)
    } catch {
        Write-Debug "Save-ZohoTokenCache: Failed to save: $_"
    }
}

# Load cached token on module import so the first call doesn't need a refresh
Load-ZohoTokenCache

function Get-ZohoTokenLock {
    $retries = 30
    $staleThresholdSeconds = 10
    for ($i = 0; $i -lt $retries; $i++) {
        if (Test-Path $script:ZohoTokenLockPath) {
            $lockFile = Get-Item $script:ZohoTokenLockPath
            if (([datetime]::UtcNow - $lockFile.LastWriteTimeUtc).TotalSeconds -gt $staleThresholdSeconds) {
                Write-Warning "Get-ZohoTokenLock: Stale lock detected (age: $([math]::Round(([datetime]::UtcNow - $lockFile.LastWriteTimeUtc).TotalSeconds))s) — removing"
                try { Remove-Item $script:ZohoTokenLockPath -Force } catch {}
            }
        }
        try {
            $stream = [System.IO.File]::Open($script:ZohoTokenLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
            return $stream
        } catch { Start-Sleep -Milliseconds 100 }
    }
    return $null
}

function Release-ZohoTokenLock($stream) {
    if ($stream) { try { $stream.Close(); $stream.Dispose() } catch {} }
    try { Remove-Item $script:ZohoTokenLockPath -Force -ErrorAction SilentlyContinue } catch {}
}

function Get-ZohoAccessToken {
    if (-not $script:ZohoClientId -or -not $script:ZohoClientSecret -or -not $script:ZohoRefreshToken) { return $null }
    $now = [datetime]::UtcNow
    if ($script:ZohoAccessTokenValue -and $script:ZohoAccessTokenExpiry -gt $now.AddMinutes(1)) {
        return $script:ZohoAccessTokenValue
    }
    $lock = Get-ZohoTokenLock
    if (-not $lock) {
        Write-Warning "Get-ZohoAccessToken: Lock timeout — concurrent token refresh in progress, proceeding with stale token"
        return $script:ZohoAccessTokenValue
    }
    try {
        $now = [datetime]::UtcNow
        if ($script:ZohoAccessTokenValue -and $script:ZohoAccessTokenExpiry -gt $now.AddMinutes(1)) {
            return $script:ZohoAccessTokenValue
        }
        $body = @{
            client_id     = $script:ZohoClientId
            client_secret = $script:ZohoClientSecret
            refresh_token = $script:ZohoRefreshToken
            grant_type    = "refresh_token"
        }
        $result = Invoke-ApiCall -Uri $script:ZohoAccountsUrl -Method POST -Body $body -ContentType "application/x-www-form-urlencoded" -Domain "Bookkeeper" -Action "zoho:token-exchange" -TimeoutSec 30 -ErrorAction Stop
        $script:ZohoAccessTokenValue = $result.access_token
        $script:ZohoAccessTokenExpiry = $now.AddSeconds($result.expires_in)
        Save-ZohoTokenCache -Token $result.access_token -Expiry $script:ZohoAccessTokenExpiry
        return $result.access_token
    }
    catch {
        $script:ZohoAccessTokenValue = $null
        $script:ZohoAccessTokenExpiry = $null
        return $null
    }
    finally {
        Release-ZohoTokenLock $lock
    }
}

function Get-ZohoRateLimitStatus {
    $active = $script:ZohoCircuitBreakerExpiry -and (Get-Date) -lt $script:ZohoCircuitBreakerExpiry
    return [pscustomobject]@{
        CircuitBreakerActive = $active
        CircuitBreakerExpiry = if ($active) { $script:ZohoCircuitBreakerExpiry.ToString('o') } else { $null }
        TokenExpiry = if ($script:ZohoAccessTokenExpiry) { $script:ZohoAccessTokenExpiry.ToString('o') } else { $null }
    }
}
