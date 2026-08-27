<#
.SYNOPSIS
    Assembles a hashtable of web/MCP secret values from AWS Secrets Manager.
.DESCRIPTION
    Reads Tavily API key and Firecrawl API key from the provisioning secret
    blob. Falls back to proxy secret lookup if Get-SecretFromAws is unavailable.
    Key rotation schedules for all third-party services are documented in
    docs/Reference/KeyRotation.md.
.OUTPUTS
    Hashtable with keys: tavily_api_key, firecrawl_api_key.
#>
function Get-WebSecretBundle {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $getSecretCmd = Get-Command Get-SecretFromAws -ErrorAction SilentlyContinue
    $readProxyCmd = Get-Command Read-ProxySecret -ErrorAction SilentlyContinue

    $readSecret = {
        param($name)
        if ($getSecretCmd) { return & $getSecretCmd -KeyName $name }
        if ($readProxyCmd) { return & $readProxyCmd -KeyName $name }
        return $null
    }

    $bundle = @{
        tavily_api_key     = & $readSecret "TAVILY_API_KEY"
        firecrawl_api_key  = & $readSecret "FIRECRAWL_API_KEY"
    }

    $missing = @()
    foreach ($key in $bundle.Keys) {
        if (-not $bundle.$key) { $missing += $key }
    }
    if ($missing.Count -gt 0) {
        Write-Warning "Get-WebSecretBundle: missing keys: $($missing -join ', '). Some search capabilities will be unavailable."
    }

    return $bundle
}
