param(
    [string]$Date = (Get-Date -Format "yyyy.MM.dd"),
    [Parameter(Mandatory = $true)]
    [string]$Namespace,
    [Parameter(Mandatory = $true)]
    [string]$Iteration,
    [string]$Description = "",
    [string]$OutputDir = '~/.salmon/Tasks/Handoff',
    [string]$Content = "",
    [switch]$DryRun,
    [switch]$PassThru
)

<#
.SYNOPSIS
    Generate a session plan filename following the Print naming convention.

.DESCRIPTION
    Constructs a filename as <Date>-<Namespace>-<Iteration>-<Description>.md
    per session-plan-format.md. Handles collision with -N suffix.
    Optionally writes $Content to the file.

    This script is the single executable source of truth for the Print naming
    convention. Both Plan mode and Audit mode call this script. The human-readable
    spec lives at session-plan-format.md.

    Convention: Skills/Workflows/Shared/session-plan-format.md
    Filename:    <date>-<namespace>-<iteration>-<description>.md
    Example:     2026.06.22-secrets-port-registry-1-verify-bundle-manifest.md

.PARAMETER Date
    Date segment (default: today in yyyy.MM.dd format).

.PARAMETER Namespace
    Semantic kebab-case namespace (e.g., "secrets-port-registry").

.PARAMETER Iteration
    Alpha-sort key (e.g., "1", "3a", "3b").

.PARAMETER Description
    Short kebab-case description of what the plan addresses. Required by
    the Print convention — a warning is emitted if omitted.

.PARAMETER OutputDir
    Directory to write the plan file.
    Default: ~/.salmon/Tasks/Handoff (interactive plans await user approval off the
    Coder's auto-dispatch path — see AGENTS.md "Plan output location").
    Autonomous callers (Audit mode, Planner persona) pass -OutputDir ~/.salmon/Tasks/Code
    for ready-to-dispatch plans.

.PARAMETER Content
    Plan file content to write. If empty, no file is written (use with -PassThru
    to get the resolved filename only).

.PARAMETER DryRun
    Print what would be generated without writing.

.PARAMETER PassThru
    Output the resolved file path to the pipeline.

.EXAMPLE
    Write-SessionPlan -Namespace "secrets-registry" -Iteration "1" -Description "verify-bundles" -Content $content

.EXAMPLE
    $path = Write-SessionPlan -Namespace "adr-alignment" -Iteration "2" -Description "drift-check" -Content $md -PassThru
#>

$ErrorActionPreference = "Stop"

# Audit-mode redirect: when writing to Tasks/Code (the autonomous/ready path) and
# an override is set, honor it. This does NOT affect the Tasks/Handoff default
# (interactive plans are never auto-redirected — they must stay off the dispatch
# path until the user moves them).
if ($OutputDir -eq '~/.salmon/Tasks/Code' -and $env:AUDIT_TARGET_CODE_DIR) {
    $OutputDir = $env:AUDIT_TARGET_CODE_DIR
}

if ($OutputDir -like '~*') { $OutputDir = $OutputDir -replace '^~', $HOME }

# Resolve output directory
$resolvedDir = if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir
} else {
    $scriptDir = $PSScriptRoot
    $repoRoot = $scriptDir
    while ($repoRoot) {
        if (Test-Path (Join-Path $repoRoot "AGENTS.md") -PathType Leaf) { break }
        if (Test-Path (Join-Path $repoRoot ".git") -PathType Container) { break }
        $parent = Split-Path $repoRoot -Parent
        if ($parent -eq $repoRoot) { $repoRoot = $null; break }
        $repoRoot = $parent
    }
    if (-not $repoRoot) { $repoRoot = Join-Path $HOME "intersite-orchestrator" }
    Join-Path $repoRoot $OutputDir
}

# Validate namespace is kebab-case
if ($Namespace -notmatch '^[a-z][a-z0-9-]*$') {
    Write-Warning "Namespace '$Namespace' is not kebab-case. Convention: lowercase letters, digits, hyphens only."
}

# Warn if description is empty (Print convention requires it)
if ([string]::IsNullOrWhiteSpace($Description)) {
    Write-Warning "Description is empty. Print convention requires: <date>-<namespace>-<iteration>-<description>.md"
}

# Construct base filename
$baseFilename = $Date
$baseFilename += "-$Namespace"
$baseFilename += "-$Iteration"
if (-not [string]::IsNullOrWhiteSpace($Description)) {
    $baseFilename += "-$Description"
}
$baseFilename += ".md"

# Handle collision
$planFilename = $baseFilename
$planPath = Join-Path $resolvedDir $planFilename
$collisionSuffix = 0
while (Test-Path $planPath) {
    $collisionSuffix++
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($baseFilename)
    $planFilename = "$stem-$collisionSuffix.md"
    $planPath = Join-Path $resolvedDir $planFilename
}

if ($DryRun) {
    Write-Host "[DRY-RUN] Would generate: $planFilename"
    if ($PassThru) { return $planPath }
    return
}

# Write
if (-not [string]::IsNullOrWhiteSpace($Content)) {
    $null = New-Item -ItemType Directory -Path $resolvedDir -Force
    $Content | Out-File $planPath -Encoding utf8
    Write-Host "Generated: $planFilename"
} else {
    Write-Host "Resolved: $planFilename (no content written)"
}

if ($PassThru) { return $planPath }
