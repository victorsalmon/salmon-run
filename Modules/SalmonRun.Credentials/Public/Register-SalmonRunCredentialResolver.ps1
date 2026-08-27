function Register-SalmonRunCredentialResolver {
    <#
    .SYNOPSIS
        Registers or overrides a credential resolver.
    .DESCRIPTION
        Resolvers are named by their first word in a .env value. They receive
        the remaining words as a string array. Register a resolver to add support
        for a new secret source (e.g. 1Password, Vault, Bitwarden).
    .PARAMETER Name
        Resolver name, e.g. AWS, GitHub, Worktree.
    .PARAMETER ScriptBlock
        ScriptBlock that accepts [string[]]$Arguments and returns a string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $script:CredentialResolvers[$Name] = $ScriptBlock
}
