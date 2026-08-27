function Invoke-WorktreeGitPush {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RemoteUrl,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Token,

        [string]$RefSpec = $Branch
    )

    return Invoke-SalmonRunGitCloudPush -RemoteUrl $RemoteUrl -RefSpec $RefSpec -Token $Token |
        Select-Object -Property @{ Name = 'Success'; Expression = { $_.Success } },
                                @{ Name = 'ExitCode'; Expression = { $_.ExitCode } },
                                @{ Name = 'Remote'; Expression = { $_.Remote } },
                                @{ Name = 'Branch'; Expression = { $Branch } },
                                @{ Name = 'Batched'; Expression = { $false } }
}
