#Requires -Version 7.0

# Import audit module for Invoke-ApiCall used by all Zoho handlers
Import-Module SalmonRun.Audit -ErrorAction SilentlyContinue

$script:ModuleRoot = $PSScriptRoot
# Default audit log location. /home/node/app is not writable in this container
# (root, but the parent dir is owned by the `node` user with restrictive
# permissions in the production image). Use /tmp which is always writable,
# and let ORCHESTRATOR_AUDIT_ROOT override.
$script:AuditRoot = if ($env:ORCHESTRATOR_AUDIT_ROOT) { $env:ORCHESTRATOR_AUDIT_ROOT } else { "/tmp/bookkeeping-audit" }
$script:BookkeepingAuditLogPath = Join-Path $script:AuditRoot "bookkeeping" "audit.jsonl"

# Initialize module-scoped credential variables. Read order:
#   1. Process environment variable (set when Node.js spawns the PWSH subprocess
#      with explicit env: {...} options).
#   2. Container's /run/secrets/bookkeeping_secrets_bundle file (mounted by Swarm
#      at deploy time). This is the canonical source in production.
#   3. AWS Secrets Manager via Get-SecretFromAws (host-side path).
$bundlePath = '/run/secrets/bookkeeping_secrets_bundle'
$secretBundle = $null
if (Test-Path $bundlePath) {
    try { $secretBundle = Get-Content -LiteralPath $bundlePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch {}
}

function Get-BundleValue {
    param([string]$Name)
    $envVal = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
    if ($secretBundle -and ($secretBundle.PSObject.Properties.Name -contains $Name)) {
        return $secretBundle.$Name
    }
    return $null
}

$script:ZohoClientId         = Get-BundleValue 'ZOHO_BOOKS_ID'
$script:ZohoClientSecret     = Get-BundleValue 'ZOHO_BOOKS_SECRET'
$script:ZohoRefreshToken     = Get-BundleValue 'ZOHO_BOOKS_REFRESH'
$script:ZohoOrgIdIntersite   = Get-BundleValue 'ZOHO_BOOKS_ORG_INTERSITE'
$script:ZohoOrgIdRoomRentals = Get-BundleValue 'ZOHO_BOOKS_ORG_RENTALS'
$script:OpenRouterApiKey     = Get-BundleValue 'OPENROUTER_API_KEY'

$PublicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $PublicPath) {
    Get-ChildItem -Path $PublicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

$PrivatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $PrivatePath) {
    Get-ChildItem -Path $PrivatePath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

$HandlerPaths = @(
    (Join-Path $script:ModuleRoot 'Handlers/Zoho/*.ps1'),
    (Join-Path $script:ModuleRoot 'Handlers/Vision/*.ps1')
)
foreach ($pattern in $HandlerPaths) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        . $_.FullName
    }
}
