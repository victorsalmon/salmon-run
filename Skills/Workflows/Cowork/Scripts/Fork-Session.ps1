# Used by: .opencode/commands/fork.md and opencode.json /fork command
# Universal fork helper - creates a Fork-Stub and launches a new opencode window.
param(
    [Parameter(Mandatory = $true)]
    [string]$Goal,
    [Parameter(Mandatory = $false)]
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "Tasks/Handoff",
    [Parameter(Mandatory = $false)]
    [switch]$StubOnly,
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Resolve repo root
$repoRoot = Resolve-Path -LiteralPath "$PSScriptRoot\..\..\.." -ErrorAction Stop
$handoffDir = Join-Path -Path $repoRoot -ChildPath $OutputDir

# Generate topic slug from goal
$topic = ($Goal -replace '[^a-zA-Z0-9\s-]', '' -replace '\s+', '-').ToLower()
$topic = $topic.Trim('-')
if ($topic.Length -gt 50) { $topic = $topic.Substring(0, 50).Trim('-') }
if ($topic.Length -eq 0) { $topic = "fork" }

# Paths
$contextFile = Join-Path -Path $env:TEMP -ChildPath "fork-context-$topic.md"
$stubFile = Join-Path -Path $handoffDir -ChildPath "fork-stub-$Date-$topic.md"

# Ensure directories exist
$null = New-Item -ItemType Directory -Path $handoffDir -Force -ErrorAction SilentlyContinue

# Build a default context body. The user/model can overwrite this file before launch if desired.
$contextBody = @"
# Fork Context: $topic

**Goal**: $Goal

**Date**: $Date

## Transferred Context

This stub was created from a /fork command. The forked session should read this file and compress away everything not relevant to the goal above.

## Notes

- Original repo: $repoRoot
- Context file: $contextFile
- Fork-Stub: $stubFile
"@

Set-Content -LiteralPath $contextFile -Value $contextBody -NoNewline

# Dot-source helper functions
$helper = Join-Path -Path $repoRoot -ChildPath "Skills/Cowork/Scripts/New-ForkStub.ps1"
if (-not (Test-Path -LiteralPath $helper)) { throw "New-ForkStub.ps1 not found at $helper" }
. $helper

$stubPath = New-ForkStub -Topic $topic -Goal $Goal -ContextBody $contextBody -Date $Date -OutputDir $handoffDir

if ($DryRun) {
    Write-Host "[fork] (dry-run) Would create stub at: $stubPath"
    Write-Host "[fork] (dry-run) Would create context file at: $contextFile"
    return $stubPath
}

# Build prompt for the new window
$resolvedStub = Resolve-Path -LiteralPath $stubPath -ErrorAction Stop
$promptMsg = "Forked for: $Goal. Read the Fork-Stub at $resolvedStub, then compress away everything not relevant to this goal. Proceed."

# Escape single quotes for PowerShell command line
$escapedPrompt = $promptMsg -replace "'", "''"

Write-Host "[fork] Stub: $resolvedStub"

if ($StubOnly) {
    Write-Host "[fork] Stub-only mode. No terminal launched."
    Write-Host "[fork] Launch later with: opencode --continue --fork --prompt '$escapedPrompt'"
    return $resolvedStub
}

Write-Host "[fork] Launching new terminal..."

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "pwsh"
$psi.Arguments = "-NoProfile -Command opencode --continue --fork --prompt '$escapedPrompt'"
$psi.WorkingDirectory = $repoRoot
$psi.UseShellExecute = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal

try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    Write-Host "[fork] New terminal launched (PID: $($proc.Id))."
} catch {
    Write-Error "[fork] Failed to launch new terminal: $_"
    Write-Host "[fork] Fallback: Fork-Stub written at $resolvedStub. Launch manually:"
    Write-Host "  cd '$repoRoot' && opencode --continue --fork --prompt '$escapedPrompt'"
    exit 1
}

Write-Host "[fork] Done. Stub: $resolvedStub"
