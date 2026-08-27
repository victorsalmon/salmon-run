<#
.SYNOPSIS
    Builds a consolidated Markdown documentation bundle from the docs/ tree.

.DESCRIPTION
    Collects all .md files under docs/, generates a table of contents, and
    concatenates them into a single dated output file under docs/_build/.
    Skips existing bundles unless -Force is used.
#>
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot "..\..\docs\_build"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$DocRoot = Join-Path $RepoRoot "docs"

# ==== ENSURE OUTPUT DIRECTORY ====
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$DateStamp = Get-Date -Format "yyyy-MM-dd"
$OutputFile = Join-Path $OutputDir "ORCHESTRATOR-docs-$DateStamp.md"

if ((Test-Path $OutputFile) -and -not $Force) {
    Write-Host "[SKIP] $OutputFile already exists. Use -Force to overwrite." -ForegroundColor Yellow
    exit 0
}

# ==== COLLECT ALL DOCUMENTATION FILES ====
$DocFiles = Get-ChildItem -Path $DocRoot -Filter "*.md" -File -Recurse | Where-Object {
    $_.FullName -notlike "$OutputDir*"
} | Sort-Object FullName

Write-Host "Building documentation bundle from $($DocFiles.Count) files..." -ForegroundColor Cyan

$Lines = @()
$Lines += "# ORCHESTRATOR Documentation Bundle"
$Lines += ""
$Lines += "**Generated**: $DateStamp"
$Lines += "**Files**: $($DocFiles.Count)"
$Lines += ""
$Lines += "---"
$Lines += ""
$Lines += "## Table of Contents"
$Lines += ""

$TocEntries = @()
$ContentBlocks = @()

foreach ($File in $DocFiles) {
    $RelativePath = $File.FullName.Substring($RepoRoot.Length + 1)
    $DisplayName = $RelativePath -replace "\\", "/"
    $AnchorId = ($DisplayName -replace "[^\w\- ]", "" -replace " ", "-").ToLower()
    $TocEntries += "- [$DisplayName](#$AnchorId)"
    $ContentBlocks += ""
    $ContentBlocks += "---"
    $ContentBlocks += ""
    $ContentBlocks += "## $DisplayName"
    $ContentBlocks += ""
    $ContentBlocks += (Get-Content -Path $File.FullName -Raw).Trim()
}

$Lines += $TocEntries
$Lines += ""
$Lines += "---"
$Lines += $ContentBlocks

$Output = $Lines -join [Environment]::NewLine
Set-Content -Path $OutputFile -Value $Output -Encoding UTF8

$outLen = $Output.Length; $fileCount = $DocFiles.Count
Write-Host "[OK] Bundle written to $OutputFile ($outLen bytes, $fileCount files)" -ForegroundColor Green
