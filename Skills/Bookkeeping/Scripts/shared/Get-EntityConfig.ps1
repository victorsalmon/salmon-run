function Get-EntityConfigPath {
    $configPath = Join-Path $PSScriptRoot ".." ".." "cloud-books-entities.json"
    if (Test-Path $configPath) { return (Resolve-Path $configPath).Path }
    throw "cloud-books-entities.json not found"
}

function Get-EntityConfig {
    param([string]$Entity)
    $configPath = Get-EntityConfigPath
    $config = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
    $entityCfg = $config.entities[$Entity]
    if (-not $entityCfg) { throw "Entity '$Entity' not found in cloud-books-entities.json" }
    return @{ Config = $config; Entity = $entityCfg }
}

function Get-ExemptCategories {
    param([string]$Entity)
    $config = Get-EntityConfig -Entity $Entity
    $rootExempt = $config.Config.exempt_categories
    if ($rootExempt -and $rootExempt.ContainsKey($Entity)) {
        return @($rootExempt[$Entity])
    }
    return @()
}

function Resolve-ZohoCredentials {
    param([string]$AwsProfile = "intersite")
    if ($script:ZohoClientId -and $script:ZohoClientSecret -and $script:ZohoRefreshToken) {
        return
    }
    $envVars = @{ id = $env:ZOHO_BOOKS_ID; secret = $env:ZOHO_BOOKS_SECRET; refresh = $env:ZOHO_BOOKS_REFRESH }
    if ($envVars.id -and $envVars.secret -and $envVars.refresh) {
        $script:ZohoClientId = $envVars.id
        $script:ZohoClientSecret = $envVars.secret
        $script:ZohoRefreshToken = $envVars.refresh
        return
    }
    try {
        $secretStr = & aws secretsmanager get-secret-value --secret-id Interclaw/FRAD/Provisioning --profile $AwsProfile --region ca-central-1 --query SecretString --output text 2>&1
        if ($secretStr) {
            $secret = $secretStr | ConvertFrom-Json
            $script:ZohoClientId = $secret.ZOHO_BOOKS_ID
            $script:ZohoClientSecret = $secret.ZOHO_BOOKS_SECRET
            $script:ZohoRefreshToken = $secret.ZOHO_BOOKS_REFRESH
            return
        }
    } catch { }
    try {
        $containerId = & docker ps --filter name=FRAD_api-proxy --format "{{.ID}}" 2>$null
        if ($containerId) {
            $bundleJson = & docker exec $containerId cat /run/secrets/secrets_bundle 2>$null
            if ($bundleJson) {
                $bundle = $bundleJson | ConvertFrom-Json
                $script:ZohoClientId = $bundle.ZOHO_BOOKS_ID
                $script:ZohoClientSecret = $bundle.ZOHO_BOOKS_SECRET
                $script:ZohoRefreshToken = $bundle.ZOHO_BOOKS_REFRESH
                return
            }
        }
    } catch { }
    throw "Could not resolve Zoho credentials from env, AWS SM, or Docker proxy"
}

function Get-ZohoAccessToken {
    $body = @{
        client_id     = $script:ZohoClientId
        client_secret = $script:ZohoClientSecret
        refresh_token = $script:ZohoRefreshToken
        grant_type    = "refresh_token"
    }
    $tokenResult = Invoke-RestMethod -Uri "https://accounts.zoho.com/oauth/v2/token" -Method POST -Body $body -ContentType "application/x-www-form-urlencoded"
    $accessToken = $tokenResult.access_token
    $expiresIn = if ($tokenResult.expires_in) { $tokenResult.expires_in } else { 3600 }
    $script:ZohoTokenExpiry = (Get-Date).AddSeconds([math]::Max($expiresIn - 300, 60))
    return $accessToken
}
