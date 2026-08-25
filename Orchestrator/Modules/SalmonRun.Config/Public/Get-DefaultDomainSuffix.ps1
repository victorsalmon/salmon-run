<#
.SYNOPSIS
    Returns the default domain suffix from install.json, env var, or fallback.
.DESCRIPTION
    Checks INTERCLAW_DOMAIN_SUFFIX env var first, then reads from install.json,
    then falls back to ".example.com".
.OUTPUTS
    System.String
#>
function Get-DefaultDomainSuffix {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:INTERCLAW_DOMAIN_SUFFIX)) { return $env:INTERCLAW_DOMAIN_SUFFIX }
    try {
        $Json = Read-InstallJson
        if ($Json -and $Json.project.domainSuffix) { return $Json.project.domainSuffix }
    } catch {
        Write-Verbose "Get-DefaultDomainSuffix: Failed to read install.json: $_"
    }
    return ".example.com"
}
