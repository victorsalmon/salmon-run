<#
.SYNOPSIS
    Assembles a hashtable of marketing secret values.
.DESCRIPTION
    Reads Attio API keys (read, write, archive), Hunter API key, Smartlead API
    key, Apollo API key, ZeroBounce API key, and OpenRouter orchestrator key
    using a 4-tier resolution order:
      1. Process environment variables (set by container runtime)
      2. /run/secrets/marketer_secrets_bundle (Docker Swarm bundle)
      3. AWS Secrets Manager via Get-SecretFromAws (host-side path)
      4. Proxy secret via Read-ProxySecret (host-side path)
    Unknown keys return $null after lookup failure with a WARNING.
    Key rotation schedules for all third-party services are documented in
    docs/Reference/KeyRotation.md.
.OUTPUTS
    Hashtable with keys: AttioWriteKey, AttioReadKey, AttioArchiveKey,
    HunterApiKey, SmartleadApiKey, OpenrouterApiKey, ApolloApiKey,
    ZeroBounceApiKey.
#>
function Get-MarketerSecretBundle {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $getSecretCmd = Get-Command Get-SecretFromAws -ErrorAction SilentlyContinue
    $readProxyCmd = Get-Command Read-ProxySecret -ErrorAction SilentlyContinue

    $bundlePath = '/run/secrets/marketer_secrets_bundle'
    $secretBundle = $null
    if (Test-Path $bundlePath) {
        try { $secretBundle = Get-Content -LiteralPath $bundlePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { Write-Debug "Get-MarketerSecretBundle: failed to read/parse bundle at '$bundlePath': $_" }
    }

    $readSecret = {
        param($name)
        # Tier 1: env var
        $envVal = [System.Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
        # Tier 2: Docker Swarm secret bundle
        if ($secretBundle -and ($secretBundle.PSObject.Properties.Name -contains $name)) {
            return $secretBundle.$name
        }
        # Tier 3: AWS Secrets Manager (host-side path)
        if ($getSecretCmd) {
            try { return & $getSecretCmd -KeyName $name } catch { Write-Debug "Get-MarketerSecretBundle: AWS lookup failed for '$name': $_" }
        }
        # Tier 4: Proxy secret (host-side path)
        if ($readProxyCmd) {
            try { return & $readProxyCmd -KeyName $name } catch { Write-Debug "Get-MarketerSecretBundle: Proxy lookup failed for '$name': $_" }
        }
        return $null
    }

    $bundle = @{
        AttioWriteKey        = & $readSecret "ATTIO_WRITE_KEY"
        AttioReadKey         = & $readSecret "ATTIO_READ_KEY"
        AttioArchiveKey      = & $readSecret "ATTIO_ARCHIVE_KEY"
        HunterApiKey         = & $readSecret "HUNTER_API_KEY"
        SmartleadApiKey      = & $readSecret "SMARTLEAD_API_KEY"
        OpenrouterApiKey     = & $readSecret "OPENROUTER_API_KEY"
        ApolloApiKey         = & $readSecret "APOLLO_SEARCH"
        ApolloEnrichKey      = & $readSecret "APOLLO_ENRICH"
        ZeroBounceApiKey     = & $readSecret "ZEROBOUNCE_API_KEY"
    }

    # Log warnings for unresolvable keys
    foreach ($key in $bundle.Keys) {
        if (-not $bundle.$key) { Write-Warning "Get-MarketerSecretBundle: $key not found at any resolution level" }
    }

    return $bundle
}
