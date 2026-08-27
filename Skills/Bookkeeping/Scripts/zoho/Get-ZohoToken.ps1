<#
.SYNOPSIS
    Get a Zoho OAuth token with persistent file-based caching.
.DESCRIPTION
    Reads the bookkeeper Docker secret bundle, checks a local file cache
    (.zoho-token-cache.json), and only calls the OAuth refresh endpoint when
    the cached token is expired or missing. Keeps pipeline runs within the
    ~5/15min OAuth rate limit.
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
    Cache TTL: 55 minutes (tokens live 60 min; 5 min safety margin).
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

    # Resolve secrets from Docker bundle
    $containerId = docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}" | Select-Object -First 1
    if (-not $containerId) {
        $containerId = docker ps --filter name=is-bookkeeping --format "{{.ID}}" | Select-Object -First 1
    }
    if (-not $containerId) {
        $containerId = docker ps --filter name=Bookkeeper --format "{{.ID}}" | Select-Object -First 1
    }
    if (-not $containerId) {
        throw "Could not find Bookkeeping container — searched for FRAD_is-bookkeeping, is-bookkeeping, Bookkeeper"
    }
    $bundleJson = docker exec $containerId cat /run/secrets/secrets_bundle 2>$null
    if (-not $bundleJson) {
        $bundleJson = docker exec $containerId cat /run/secrets/bookkeeping_secrets_bundle 2>$null
    }
    if (-not $bundleJson) {
        throw "Could not read secrets bundle from container $containerId"
    }
    $cred = $bundleJson | ConvertFrom-Json
    $refreshField = if ($cred.ZOHO_BOOKS_REFRESH) { "ZOHO_BOOKS_REFRESH" }
                    else { throw "No Zoho refresh token found in secrets bundle (checked ZOHO_BOOKS_REFRESH)" }

    # Check cache (unless ForceRefresh)
    if (-not $ForceRefresh -and (Test-Path -LiteralPath $CachePath)) {
        try {
            $cached = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
            $expiresAt = if ($cached.expires_at -is [datetime]) { $cached.expires_at } else { [datetime]::ParseExact($cached.expires_at, 'o', $null) }
            if ($expiresAt -gt (Get-Date) -and $cached.account_name -eq $AccountName) {
                Write-Information "[PRP TOKEN] Using cached token for $AccountName (expires $($cached.expires_at))" -Tags PRP
                return @{
                    access_token = $cached.access_token
                    expires_at   = $cached.expires_at
                    account_name = $AccountName
                    from_cache   = $true
                }
            }
        } catch {
            Write-Warning "[PRP TOKEN] Cache read failed: $_ — will refresh"
        }
    }

    # Refresh token via OAuth
    Write-Information "[PRP TOKEN] Refreshing token for $AccountName..." -Tags PRP
    $tokenBody = @{
        refresh_token = $cred.$refreshField
        client_id     = $cred.ZOHO_BOOKS_ID
        client_secret = $cred.ZOHO_BOOKS_SECRET
        grant_type    = "refresh_token"
    }
    try {
        $response = Invoke-RestMethod -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $tokenBody -ErrorAction Stop
    } catch {
        $sanitizedMessage = $_.Exception.Message -replace 'client_secret=[^&]+', 'client_secret=REDACTED' -replace 'refresh_token=[^&]+', 'refresh_token=REDACTED'
        throw "OAuth refresh failed for $AccountName`: $sanitizedMessage"
    }

    $expiresAt = (Get-Date).AddMinutes(55).ToString('o')
    $result = @{
        access_token = $response.access_token
        expires_at   = $expiresAt
        account_name = $AccountName
        from_cache   = $false
    }

    # Write cache
    if (-not $SkipCache) {
        try {
            $result | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $CachePath -Encoding utf8 -NoNewline
            # Restrict cache file to current user only
            $acl = Get-Acl -LiteralPath $CachePath
            $acl.SetAccessRuleProtection($true, $false)
            $userRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                "$env:USERDOMAIN\$env:USERNAME", 'Read,Write', 'Allow')
            $acl.SetAccessRule($userRule)
            $acl | Set-Acl -LiteralPath $CachePath
            Write-Information "[PRP TOKEN] Token cached to $CachePath (expires $expiresAt)" -Tags PRP
        } catch {
            Write-Warning "[PRP TOKEN] Failed to write cache: $_"
        }
    }

    Write-Information "[PRP TOKEN] Token refreshed for $AccountName (expires $expiresAt)" -Tags PRP
    return $result
}
