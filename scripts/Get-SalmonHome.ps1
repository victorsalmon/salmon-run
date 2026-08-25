#Requires -Version 7.0
<#
.SYNOPSIS
    Returns the salmon-run runtime home, defaulting to ~/.salmon.
.DESCRIPTION
    Resolves $env:SALMON_RUN_HOME, then ~/.salmon, then the repo root.
    Use this for all task queues, logs, cache, and runtime state.
#>
[CmdletBinding()]
param()

if ($env:SALMON_RUN_HOME) { return $env:SALMON_RUN_HOME }

$salmonHome = Join-Path $HOME '.salmon'
if (-not (Test-Path $salmonHome)) {
    $null = New-Item -ItemType Directory -Path $salmonHome -Force
}

return $salmonHome
