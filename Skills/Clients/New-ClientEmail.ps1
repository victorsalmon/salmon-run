param(
    [Parameter(Mandatory)]
    [string]$ClientSlug,

    [Parameter(Mandatory)]
    [string]$MailboxName,

    [Parameter(Mandatory)]
    [string]$Domain,

    [int]$Quota = 1024,

    [string]$Provider,

    [string]$ConfigPath = "$HOME\intersite-orchestrator\Infrastructure\clients\providers-config.json",

    [switch]$StoreInAwsSm,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Resolve provider adapter from config
if (-not (Test-Path $ConfigPath)) {
    $altPath = Join-Path $PSScriptRoot "..\..\Infrastructure\clients\providers-config.json"
    if (Test-Path $altPath) { $ConfigPath = $altPath }
    else { throw "providers-config.json not found at $ConfigPath or $altPath" }
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$emailConfig = $config.email

$providerKey = if ($Provider) { $Provider } else { $emailConfig.active_provider }
$providerDef = $emailConfig.providers.$providerKey

if (-not $providerDef) {
    throw "Provider '$providerKey' not found in config. Available: $($emailConfig.providers.PSObject.Properties.Name -join ', ')"
}

# Generate secure password
$password = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object { [char]$_ })
$password += "!$((Get-Random -Minimum 10 -Maximum 99))"

$email = "$MailboxName@$Domain"
$quotaToUse = if ($Quota) { $Quota } else { $providerDef.default_quota }

Write-Host "Email provisioning plan:"
Write-Host "  Provider:     $providerKey ($($providerDef.type))"
Write-Host "  Mailbox:      $email"
Write-Host "  Domain:       $Domain"
Write-Host "  Quota:        ${quotaToUse}MB"
Write-Host "  Adapter:      $($providerDef.adapter_path)"
Write-Host "  StoreInAwsSm: $($StoreInAwsSm.IsPresent)"
Write-Host ""

if ($WhatIf) {
    Write-Host "[WhatIf] Would call createMailbox('$email', '***', '$Domain', $quotaToUse)"
    if ($StoreInAwsSm) {
        Write-Host "[WhatIf] Would write credentials to AWS SM at ORCHESTRATOR/Production/Clients/$ClientSlug/email"
    }
    Write-Host "[WhatIf] Would append '$email' to IMAP monitoring registry"
    Write-Host ""
    Write-Host "Connection string: IMAP: $($providerDef.type) / $email / ***"
    return @{
        Email      = $email
        Provider   = $providerKey
        Domain     = $Domain
        Quota      = $quotaToUse
        Adapter    = $providerDef.adapter_path
        WhatIf     = $true
    }
}

# Dynamically load the adapter
$adapterPath = Join-Path (Split-Path $ConfigPath -Parent) $providerDef.adapter_path
if (-not (Test-Path $adapterPath)) {
    $adapterPath = Join-Path $PSScriptRoot "..\..\$($providerDef.adapter_path)"
}
if (-not (Test-Path $adapterPath)) {
    throw "Adapter not found at expected paths (tried: $adapterPath)"
}

Write-Host "Loading adapter from: $adapterPath"

# Load Node.js adapter via node
$scriptBlock = @"
const { $providerKey } = require('$adapterPath');
const adapter = new $providerKey({
    host: '$($providerDef.base_url)',
    username: process.env.CPANEL_USERNAME || 'admin',
    apiToken: process.env.CPANEL_API_TOKEN || process.env.CPANEL_TOKEN || '',
});
adapter.createMailbox('$email', '$password', '$Domain', $quotaToUse)
    .then(r => console.log(JSON.stringify(r)))
    .catch(e => { console.error(e.message); process.exit(1); });
"@

$result = node -e $scriptBlock 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Adapter call failed: $result"
}

Write-Host "Mailbox created: $email"

if ($StoreInAwsSm) {
    $secretName = "ORCHESTRATOR/Production/Clients/$ClientSlug/email"
    $secretValue = @{
        email    = $email
        password = $password
        host     = $providerDef.base_url
        provider = $providerKey
    } | ConvertTo-Json -Compress

    try {
        aws secretsmanager create-secret --name $secretName --secret-string $secretValue 2>&1 | Out-Null
        Write-Host "Credentials stored in AWS SM: $secretName"
    } catch {
        Write-Warning "Failed to store credentials in AWS SM: $_"
    }
}

# Append to IMAP monitoring registry
$registryPath = Join-Path (Split-Path $ConfigPath -Parent) "email-monitor-registry.json"
$registry = @()
if (Test-Path $registryPath) {
    $registry = Get-Content $registryPath -Raw | ConvertFrom-Json
}
$entry = @{
    email    = $email
    domain   = $Domain
    client   = $ClientSlug
    added_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    provider = $providerKey
}
$registry += $entry
$registry | ConvertTo-Json | Set-Content $registryPath
Write-Host "Registered '$email' for IMAP monitoring"

return @{
    Email      = $email
    Provider   = $providerKey
    Domain     = $Domain
    Quota      = $quotaToUse
    CredentialStore = if ($StoreInAwsSm) { "AWS SM: ORCHESTRATOR/Production/Clients/$ClientSlug/email" } else { "local variable (not persisted)" }
}
