#Requires -Version 7.0
<#
.SYNOPSIS
    Repository Mermaid diagram chunking for salmon-run.
.DESCRIPTION
    Scans Markdown files for fenced Mermaid blocks and produces model-ingestible
    chunks with frontmatter, either in memory or written to disk.
#>

$script:ModuleRoot = $PSScriptRoot

$__privatePath = Join-Path $script:ModuleRoot 'Private'
if (Test-Path $__privatePath) {
    Get-ChildItem -Path "$__privatePath\*.ps1" -Recurse -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }
}

$__publicPath = Join-Path $script:ModuleRoot 'Public'
if (Test-Path $__publicPath) {
    Get-ChildItem -Path "$__publicPath\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { . $_.FullName }
}
