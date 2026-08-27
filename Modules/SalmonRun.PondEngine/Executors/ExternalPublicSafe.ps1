<#
.SYNOPSIS
    Public-safe placeholder for non-local salmon-run executor providers.

.DESCRIPTION
    This file is a drop-in placeholder for external provider executors
    (OpenCode, Devin, OpenRouter, DeepInfra, etc.). It does not contain
    fleet-specific hostnames, credentials, PII, or internal tooling paths.

    When invoked directly it:
    - Resolves credential names from the execution profile / SalmonRun.Credentials.
    - Writes a clear failure marker and log explaining that the external
      provider must be configured by the user.

    Public consumers can replace this file with a real provider adapter that
    reads SalmonRun.Credentials without leaking secrets into logs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('coder','reviewer','auditor','qa','planner','project','project-planner','project-reviewer')]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$LanePath,

    [Parameter(Mandatory)]
    [string]$RepoDir,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles,

    [string]$Provider = 'external',

    [string[]]$Credentials = @()
)

$ErrorActionPreference = 'Stop'

try {
    $log = @()
    $log += "[$(Get-Date -Format 'o')] Public-safe placeholder for provider '$Provider', role '$Role'"
    $log += "Lane: $LanePath"
    $log += "Repo: $RepoDir"
    $log += "Plans: $($PlanFiles -join ', ')"

    # Resolve credential names from SalmonRun.Credentials if available, but
    # do not log the values.
    $credentialValues = @()
    if ($Credentials -and (Get-Command Get-SalmonRunCredential -ErrorAction SilentlyContinue)) {
        $salmonHome = if (Get-Command Get-SalmonHome -ErrorAction SilentlyContinue) { Get-SalmonHome } else { Join-Path $HOME '.salmon' }
        $envPath = Join-Path $salmonHome '.env'
        foreach ($name in $Credentials) {
            $value = $null
            try { $value = Get-SalmonRunCredential -Name $name -EnvPath $envPath } catch { }
            if ($null -ne $value) { $credentialValues += $name }
        }
    }

    $log += "Credentials resolved: $($credentialValues -join ', ')"
    $log += "The '$Provider' provider is not configured in this public salmon-run package."
    $log += "Install the provider CLI and replace this placeholder with a real adapter."

    $log | Set-Content -LiteralPath (Join-Path $LanePath 'executor.log') -Encoding utf8 -NoNewline

    "External provider '$Provider' is not configured in the public package." | Set-Content -LiteralPath (Join-Path $LanePath '.failed') -Encoding utf8 -NoNewline
    exit 1
} catch {
    $_.Exception.Message | Set-Content -LiteralPath (Join-Path $LanePath '.failed') -Encoding utf8 -NoNewline
    exit 1
}
