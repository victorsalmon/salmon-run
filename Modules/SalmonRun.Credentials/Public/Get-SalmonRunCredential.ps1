function Get-SalmonRunCredential {
    <#
    .SYNOPSIS
        Resolves a single named credential from the Salmon Run .env file.
    .DESCRIPTION
        Loads ~/.salmon/.env (or a provided path), finds the named key, and
        resolves it through any registered resolver. Returns null if the key
        is missing or the resolver fails.
    .PARAMETER Name
        Name of the credential to retrieve.
    .PARAMETER EnvPath
        Optional path to a .env file.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$EnvPath
    )

    $envValues = Get-SalmonRunEnvFile -Path $EnvPath
    if (-not $envValues.Contains($Name)) { return $null }

    return Resolve-SalmonRunCredentialValue -Value $envValues[$Name]
}
