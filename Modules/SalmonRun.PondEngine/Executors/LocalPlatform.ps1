<#
.SYNOPSIS
    Public-safe stub for the deprecated local platform executor.

.DESCRIPTION
    This file is a placeholder for the public salmon-run package. It does not
    contain fleet-specific hostnames, credentials, PII, or internal tooling.
    See ExternalPublicSafe.ps1 for the shared implementation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('coder','reviewer','auditor','qa','planner','project','project-planner','project-reviewer','investigator')]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$LanePath,

    [Parameter(Mandatory)]
    [string]$RepoDir,

    [string]$Provider = 'local-platform',

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

& (Join-Path $PSScriptRoot 'ExternalPublicSafe.ps1') -Role $Role -LanePath $LanePath -RepoDir $RepoDir -Provider $Provider -PlanFiles $PlanFiles
