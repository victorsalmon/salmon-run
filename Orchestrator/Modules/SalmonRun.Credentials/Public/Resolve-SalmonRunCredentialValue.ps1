function Resolve-SalmonRunCredentialValue {
    <#
    .SYNOPSIS
        Resolves a raw .env value through a registered credential resolver.
    .DESCRIPTION
        If the value starts with a registered resolver name (case-insensitive)
        followed by arguments, the resolver is invoked. Otherwise the value is
        returned as a literal. This makes the system open and extensible: new
        sources can be registered without modifying the core.
    .PARAMETER Value
        The raw string from a .env file.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    $tokens = $Value -split '\s+'
    $source = $tokens[0]
    $arguments = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }

    $resolver = if ($script:CredentialResolvers.ContainsKey($source)) {
        $script:CredentialResolvers[$source]
    } else {
        $null
    }

    if ($resolver) {
        try {
            return & $resolver -Arguments $arguments
        } catch {
            Write-Warning "Credential resolver '$source' failed: $($_.Exception.Message)"
            return $null
        }
    }

    # No registered resolver: treat the original value as a literal.
    return $Value
}
