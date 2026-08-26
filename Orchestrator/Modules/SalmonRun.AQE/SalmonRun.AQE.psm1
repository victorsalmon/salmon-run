#Requires -Version 7.0
<#
.SYNOPSIS
    Public Agentic Quality Engineering (AQE) runner for salmon-run.
.DESCRIPTION
    Runs a configurable quality-gate suite (Pester, documentation lint,
    property tests, and an optional AQE bridge scan) and returns a structured
    report. The bridge call is best-effort and does not fail the runner when
    the bridge is unreachable.
#>

# Do not set strict mode here; the runner invokes external test scripts
# and Pester under the caller's environment.

$script:ModuleRoot = $PSScriptRoot

$__privatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $__privatePath) {
    Get-ChildItem -Path "$__privatePath\*.ps1" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }
}

$__publicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $__publicPath) {
    Get-ChildItem -Path "$__publicPath\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }
}
