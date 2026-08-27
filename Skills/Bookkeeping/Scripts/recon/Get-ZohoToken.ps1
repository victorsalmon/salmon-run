<#
.SYNOPSIS
    Get a Zoho OAuth token with persistent file-based caching.
.DESCRIPTION
    Checks a local file cache FIRST before touching the Docker bundle or OAuth.
    Only calls the OAuth refresh endpoint when the cached token is expired or missing.
    Keeps pipeline runs within the ~5/15min OAuth rate limit.

    Cache-first reorder: if a valid cached token exists for this account, use it
    immediately — no Docker bundle read, no OAuth call, no new Zoho session.

    Also exports Revoke-ZohoToken to clean up stale sessions at pipeline end.
.PARAMETER AccountName
    Logical account name for cache scoping (e.g. "RBC-INTERSITE").
.PARAMETER OrgId
    Zoho organization ID.
.PARAMETER CachePath
    Path to the token cache JSON file. Default: .zoho-token-cache.json
.PARAMETER ForceRefresh
    Skip cache and force a new OAuth refresh.
.PARAMETER SkipCache
    Read-only mode — do NOT write to cache.
.EXAMPLE
    $token = Get-ZohoToken -AccountName "RBC-INTERSITE" -OrgId "925048093"
.EXAMPLE
    Get-ZohoToken -AccountName "TD-MLM" -OrgId "925048094" -ForceRefresh
.NOTES
    Cache format: { access_token: "...", expires_at: "ISO8601", account_name: "..." }
    Cache TTL: 50 minutes (tokens live 60 min; 10 min safety margin).
#>

function Get-ZohoToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AccountName,

        [Parameter(Mandatory)]
        [string]$OrgId,

        [string]$CachePath = $(Join-Path $env:USERPROFILE ".zoho-token-cache.json"),

        [switch]$ForceRefresh,

        [switch]$SkipCache
    )

    # ── Step 1: Check cache first (no Docker bundle, no OAuth) ──────────
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $CachePath)) {
        try {
            $cached = Get-Content -LiteralPath $CachePath -Raw -Encoding utf8 | ConvertFrom-Json
            $expiresAt = if ($cached.expires_at -is [datetime]) { $cached.expires_at } else { [datetime]::ParseExact($cached.expires_at, 'o', $null) }
            if ($expiresAt -gt (Get-Date) -and $cached.account_name -eq $AccountName) {
                # Test if token is actually valid with a lightweight call
                try {
                    $testHeaders = @{ Authorization = "Zoho-oauthtoken $($cached.access_token)"; "Content-Type" = "application/json" }
                    $null = Invoke-RestMethod -Uri "https://www.zohoapis.com/books/v3/settings/organization?organization_id=$OrgId" -Headers $testHeaders -Method GET -ErrorAction Stop
                    Write-Information "[PRP TOKEN] Using cached token for $AccountName (expires $($cached.expires_at), validated)" -Tags PRP
                    return @{
                        access_token = $cached.access_token
                        expires_at   = $cached.expires_at
                        account_name = $AccountName
                        from_cache   = $true
                    }
                } catch {
                    Write-Warning "[PRP TOKEN] Cached token expired or invalid — will refresh"
                }
            }
        } catch {
            Write-Warning "[PRP TOKEN] Cache read failed: $_ — will refresh"
        }
    }

    # ── Step 2: Resolve secrets from Docker bundle or env vars ──────────
    $cred = $null
    $containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" | Select-Object -First 1
    if (-not $containerId) { $containerId = docker ps --filter name=is-bookkeeping --format "{{.ID}}" | Select-Object -First 1 }
    if (-not $containerId) { $containerId = docker ps --filter name=Bookkeeper --format "{{.ID}}" | Select-Object -First 1 }

    if ($containerId) {
        $bundleJson = docker exec $containerId cat /run/secrets/bookkeeping_secrets_bundle 2>$null
        if ($bundleJson) {
            $parsed = $bundleJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed -and $parsed.ZOHO_BOOKS_REFRESH) {
                $cred = $parsed
            }
        }
    }

    # Fallback to env vars if bundle is empty or container not available
    if (-not $cred) {
        if ($env:ZOHO_BOOKS_REFRESH) {
            $cred = [PSCustomObject]@{
                ZOHO_BOOKS_REFRESH = $env:ZOHO_BOOKS_REFRESH
                ZOHO_BOOKS_ID      = $env:ZOHO_BOOKS_ID
                ZOHO_BOOKS_SECRET  = $env:ZOHO_BOOKS_SECRET
            }
        } else {
            throw "No Zoho refresh token found — checked Docker secrets bundle and env vars"
        }
    }

    # ── Step 3: Refresh token via OAuth ─────────────────────────────────
    Write-Information "[PRP TOKEN] Refreshing token for $AccountName..." -Tags PRP
    $tokenBody = @{
        refresh_token = $cred.ZOHO_BOOKS_REFRESH
        client_id     = $cred.ZOHO_BOOKS_ID
        client_secret = $cred.ZOHO_BOOKS_SECRET
        grant_type    = "refresh_token"
    }
    try {
        $response = Invoke-RestMethod -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $tokenBody -ErrorAction Stop
    } catch {
        throw "OAuth refresh failed for $AccountName`: $($_.Exception.Message)"
    }

    $expiresAt = (Get-Date).AddMinutes(50).ToString('o')
    $result = @{
        access_token = $response.access_token
        expires_at   = $expiresAt
        account_name = $AccountName
        from_cache   = $false
    }

    # ── Step 4: Revoke the OLD token before caching the new one ─────────
    # If we had a previous cached token, revoke it to prevent session leak
    $oldToken = $null
    if (Test-Path -LiteralPath $CachePath) {
        try {
            $old = Get-Content -LiteralPath $CachePath -Raw -Encoding utf8 | ConvertFrom-Json
            $oldToken = $old.access_token
        } catch {}
    }
    if ($oldToken -and $oldToken -ne $response.access_token) {
        try {
            $revokeBody = @{
                token        = $oldToken
                client_id    = $cred.ZOHO_BOOKS_ID
                client_secret = $cred.ZOHO_BOOKS_SECRET
            }
            Invoke-RestMethod -Uri "https://accounts.zoho.com/oauth/v2/token/revoke" -Method POST -Body $revokeBody -ErrorAction SilentlyContinue | Out-Null
            Write-Information "[PRP TOKEN] Revoked previous token" -Tags PRP
        } catch {
            Write-Warning "[PRP TOKEN] Failed to revoke previous token: $_"
        }
    }

    # ── Step 5: Write cache ────────────────────────────────────────────
    if (-not $SkipCache) {
        try {
            $result | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $CachePath -Encoding utf8 -NoNewline
            Write-Information "[PRP TOKEN] Token cached to $CachePath (expires $expiresAt)" -Tags PRP
        } catch {
            Write-Warning "[PRP TOKEN] Failed to write cache: $_"
        }
    }

    Write-Information "[PRP TOKEN] Token refreshed for $AccountName (expires $expiresAt)" -Tags PRP
    return $result
}

function Revoke-ZohoToken {
    <#
    .SYNOPSIS
        Revoke a Zoho OAuth access token to close its session.
    .DESCRIPTION
        Call at pipeline end to clean up the token session.
        Only revokes if the token was freshly acquired (not from cache).
        Revokes via POST /oauth/v2/token/revoke.
    .PARAMETER Token
        The access token to revoke.
    .PARAMETER TokenResult
        The full result object from Get-ZohoToken (checks from_cache).
    .PARAMETER ClientId
        Zoho Books client ID. Falls back to env var or Docker bundle.
    .PARAMETER ClientSecret
        Zoho Books client secret. Falls back to env var or Docker bundle.
    .EXAMPLE
        Revoke-ZohoToken -Token "1000.abc..." -TokenResult $tokenResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter()]
        [hashtable]$TokenResult,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$ClientSecret
    )

    # Don't revoke cached tokens — they're still valid for reuse
    if ($TokenResult -and $TokenResult.from_cache) {
        Write-Information "[PRP REVOKE] Token was from cache — keeping it for reuse" -Tags PRP
        return
    }

    # Resolve credentials if not provided
    if (-not $ClientId -or -not $ClientSecret) {
        $containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" | Select-Object -First 1
        if (-not $containerId) { $containerId = docker ps --filter name=is-bookkeeping --format "{{.ID}}" | Select-Object -First 1 }
        if (-not $containerId) { $containerId = docker ps --filter name=Bookkeeper --format "{{.ID}}" | Select-Object -First 1 }
        if ($containerId) {
            $bundleJson = docker exec $containerId cat /run/secrets/bookkeeping_secrets_bundle 2>$null
            if ($bundleJson) {
                $cred = $bundleJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($cred) {
                    $ClientId = $cred.ZOHO_BOOKS_ID
                    $ClientSecret = $cred.ZOHO_BOOKS_SECRET
                }
            }
        }
        if (-not $ClientId) { $ClientId = $env:ZOHO_BOOKS_ID }
        if (-not $ClientSecret) { $ClientSecret = $env:ZOHO_BOOKS_SECRET }
    }

    if (-not $ClientId -or -not $ClientSecret) {
        Write-Warning "[PRP REVOKE] Cannot revoke token — no client credentials available"
        return
    }

    try {
        $revokeBody = @{
            token         = $Token
            client_id     = $ClientId
            client_secret = $ClientSecret
        }
        $null = Invoke-RestMethod -Uri "https://accounts.zoho.com/oauth/v2/token/revoke" -Method POST -Body $revokeBody -ErrorAction Stop
        Write-Information "[PRP REVOKE] Token revoked successfully" -Tags PRP
    } catch {
        Write-Warning "[PRP REVOKE] Failed to revoke token: $_"
    }
}
