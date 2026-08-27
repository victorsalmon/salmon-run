<#
.SYNOPSIS
    Resolves workspace repository URLs from install.json, env vars, or AWS SM.
.DESCRIPTION
    Checks INSTALL_WORKSPACE_REPOS env var first, then reads from install.json,
    then falls back to AWS Secrets Manager. DEPRECATED parameter -InstallEnvPath
    is renamed to -InstallJsonPath; both work for backward compatibility.
.PARAMETER InstallJsonPath
    Path to install.json. Defaults to Find-InstallJsonPath.
.PARAMETER ProjectCode
    Project code for AWS SM lookups.
.PARAMETER SsoProfile
    AWS SSO profile name.
.PARAMETER SecretsRegion
    AWS region for Secrets Manager.
.OUTPUTS
    System.String -- comma-separated repo URLs.
#>
function Resolve-WorkspaceRepos {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$InstallJsonPath,
        [string]$ProjectCode,
        [string]$SsoProfile,
        [string]$SecretsRegion
    )

    $repos = ""

    # 1. Check process env
    $existing = Get-Item -Path "Env:\INSTALL_WORKSPACE_REPOS" -ErrorAction SilentlyContinue
    if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace($existing.Value)) {
        $repos = $existing.Value
    }

    # 2. Check install.json
    if ([string]::IsNullOrWhiteSpace($repos)) {
        $InstallJson = Read-InstallJson -Path $InstallJsonPath
        if ($InstallJson -and $InstallJson.workspace.repos) {
            $repos = $InstallJson.workspace.repos -join ','
        }
    }

    # 3. Fallback: AWS Secrets Manager
    if ([string]::IsNullOrWhiteSpace($repos) -and -not [string]::IsNullOrWhiteSpace($ProjectCode) -and -not [string]::IsNullOrWhiteSpace($SsoProfile)) {
        $repos = Get-SecretFromAws -KeyName "INSTALL_WORKSPACE_REPOS" -SsoProfile $SsoProfile
        if (-not [string]::IsNullOrWhiteSpace($repos)) {
            Write-SetupLog "Workspace repos loaded from AWS SM: $repos"
        }
    }

    Set-Item -Path "Env:\INSTALL_WORKSPACE_REPOS" -Value $repos
    Write-SetupLog "Workspace repos: $repos"
    return $repos
}
