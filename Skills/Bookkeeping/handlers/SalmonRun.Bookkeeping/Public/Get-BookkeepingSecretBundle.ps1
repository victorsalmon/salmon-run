<#
.SYNOPSIS
    Assembles a hashtable of Bookkeeper secret values and initializes the
    module-scoped credential variables consumed by all Zoho handlers.
.DESCRIPTION
    Resolution order:
      1. Process environment variables (e.g. ZOHO_BOOKS_ID) — set by the
         container's Node.js server when spawning PWSH subprocesses.
      2. /run/secrets/bookkeeping_secrets_bundle — Swarm-mounted file (canonical
         in-container source, written at deploy time by Publish-FleetStack).
      3. AWS Secrets Manager via Get-SecretFromAws (host-side path).
      4. Proxy secret via Read-ProxySecret (host-side path).
    Side-effect: writes the resolved values to $script:ZohoClientId,
    $script:ZohoClientSecret, $script:ZohoRefreshToken, $script:ZohoOrgIdIntersite,
    and $script:ZohoOrgIdRoomRentals so the handler functions (e.g. Get-ZohoBankAccounts)
    can read them without each function re-fetching.
.OUTPUTS
    Hashtable with keys: ZohoClientId, ZohoClientSecret, ZohoRefreshToken,
    ZohoOrgIdIntersite, ZohoOrgIdRoomRentals, CloudTaxT2Url, VisionApiKey,
    PlaidClientId, PlaidSecret. VisionApiKey, PlaidClientId, and PlaidSecret
    return $null with a WARNING if not found (not currently provisioned).
#>
function Get-BookkeepingSecretBundle {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $getSecretCmd = Get-Command Get-SecretFromAws -ErrorAction SilentlyContinue
    $readProxyCmd = Get-Command Read-ProxySecret -ErrorAction SilentlyContinue

    $bundlePath = '/run/secrets/bookkeeping_secrets_bundle'
    $secretBundle = $null
    if (Test-Path $bundlePath) {
        try {
            $secretBundle = Get-Content -LiteralPath $bundlePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-SetupLog "Failed to load Bookkeeper secret bundle from $bundlePath : $_" -Level ERROR
        }
    }

    $readSecret = {
        param($name)
        $envVal = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
        if ($secretBundle -and ($secretBundle.PSObject.Properties.Name -contains $name)) {
            return $secretBundle.$name
        }
        try {
            if ($getSecretCmd) { return & $getSecretCmd -KeyName $name -ErrorAction SilentlyContinue }
            if ($readProxyCmd) { return & $readProxyCmd -KeyName $name -ErrorAction SilentlyContinue }
        } catch {
            Write-Verbose "Get-BookkeepingSecretBundle: secret lookup failed for $name : $_"
        }
        return $null
    }

    $bundle = @{
        ZohoClientId          = & $readSecret "ZOHO_BOOKS_ID"
        ZohoClientSecret      = & $readSecret "ZOHO_BOOKS_SECRET"
        ZohoRefreshToken      = & $readSecret "ZOHO_BOOKS_REFRESH"
        ZohoOrgIdIntersite    = & $readSecret "ZOHO_BOOKS_ORG_INTERSITE"
        ZohoOrgIdRoomRentals  = & $readSecret "ZOHO_BOOKS_ORG_RENTALS"
        CloudTaxT2Url         = & $readSecret "CLOUDTAX_INTERSITE_T2_URL"
        VisionApiKey          = & $readSecret "VISION_API_KEY"
        PlaidClientId         = & $readSecret "PLAID_CLIENT_ID"
        PlaidSecret           = & $readSecret "PLAID_SECRET"
    }

    # Warn about unresolvable keys that are documented but not currently provisioned
    if (-not $bundle.VisionApiKey) { Write-Warning "Get-BookkeepingSecretBundle: VisionApiKey not found at any resolution level" }
    if (-not $bundle.PlaidClientId) { Write-Warning "Get-BookkeepingSecretBundle: PlaidClientId not found at any resolution level" }
    if (-not $bundle.PlaidSecret) { Write-Warning "Get-BookkeepingSecretBundle: PlaidSecret not found at any resolution level" }

    # Initialize module-scoped variables so the Zoho handlers can read them
    # without each call refetching. The handlers (Expenses.ps1, BankAccounts.ps1,
    # etc.) all reference $script:ZohoClientId, $script:ZohoClientSecret, etc.
    $script:ZohoClientId         = $bundle.ZohoClientId
    $script:ZohoClientSecret     = $bundle.ZohoClientSecret
    $script:ZohoRefreshToken     = $bundle.ZohoRefreshToken
    $script:ZohoOrgIdIntersite   = $bundle.ZohoOrgIdIntersite
    $script:ZohoOrgIdRoomRentals = $bundle.ZohoOrgIdRoomRentals

    return $bundle
}
