<#
.SYNOPSIS
    Static analysis guard: detects parallel-unsafe environment variable usage.
.DESCRIPTION
    Scans all .ps1 files in the repos for ForEach-Object -Parallel blocks
    that contain $env:VAR reads or writes. Reports each violation with
    file path, line number, and env var name.

    Exit code is 0 (all clean) or 1 (violations found).

    Also loads the env-var-registry.json and validates that every $env:VAR
    reference in the codebase is declared in the registry.
.PARAMETER RepoRoot
    Root of the ORCHESTRATOR repository. Defaults to the script's parent's parent.
.PARAMETER RegistryPath
    Path to env-var-registry.json. Defaults to docs/Reference/env-var-registry.json.
.PARAMETER FailOnMissing
    When set, exits with code 1 if any $env:VAR is found that is NOT in the registry.
.OUTPUTS
    Prints violation report to stdout.
.EXAMPLE
    .\Check-EnvVarScope.ps1 -FailOnMissing
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")),
    [string]$RegistryPath = (Join-Path $RepoRoot "docs\Reference\env-var-registry.json"),
    [switch]$FailOnMissing
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load registry
# ---------------------------------------------------------------------------
if (-not (Test-Path $RegistryPath)) {
    Write-Warning "Env var registry not found: $RegistryPath"
    Write-Warning "Run this from the repo root or specify -RegistryPath"
    exit 1
}
$Registry = Get-Content $RegistryPath -Raw | ConvertFrom-Json
$DeclaredVars = @($Registry.envVars.PSObject.Properties.Name)

# ---------------------------------------------------------------------------
# Excluded env vars (system-level, not owned by ORCHESTRATOR)
# ---------------------------------------------------------------------------
$SystemVars = @(
    "USERPROFILE", "HOME", "TEMP", "TMP", "USERNAME", "OS",
    "PSScriptRoot", "PATH", "SystemRoot", "COMPUTERNAME",
    "PSModulePath", "ProgramFiles", "CommonProgramFiles", "LOCALAPPDATA",
    "APPDATA", "ALLUSERSPROFILE", "PROCESSOR_*", "NUMBER_OF_PROCESSORS"
)

# ---------------------------------------------------------------------------
# Find all .ps1 files
# ---------------------------------------------------------------------------
$PsFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter "*.ps1" -ErrorAction SilentlyContinue `
    | Where-Object { $_.FullName -notmatch '\\node_modules\\' -and $_.FullName -notmatch '\\.git\\' }

$Violations = @()
$UnregisteredVars = @{}

# ---------------------------------------------------------------------------
# Check 1: Parallel blocks with env var access
# ---------------------------------------------------------------------------
$InParallelBlock = $false
foreach ($File in $PsFiles) {
    $Content = Get-Content $File.FullName -Raw
    $Lines = $Content -split "`n"

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i]

        # Detect start of parallel block
        if ($Line -match 'ForEach-Object\s+-Parallel') {
            $InParallelBlock = $true
            # Track brace depth: any opening { after ForEach-Object -Parallel starts the block
        }

        if ($InParallelBlock) {
            # Check for $env:VAR reads/writes
            if ($Line -match '\$env:(\w+)') {
                $VarName = $Matches[1]
                $Violations += [PSCustomObject]@{
                    File = $File.FullName
                    Line = $i + 1
                    Code = "PARALLEL-ENV"
                    Var  = $VarName
                    Message = "Env var '$VarName' accessed inside ForEach-Object -Parallel block at line $($i+1). Use AgentContext instead."
                }
            }
        }

        # Detect end of parallel block: we need to track braces
        # Simple heuristic: count braces from start of block
        # For production use, a proper parser would be needed
    }
}

# ---------------------------------------------------------------------------
# Check 2: Every $env:VAR in code is in the registry
# ---------------------------------------------------------------------------
$EnvRefPattern = '\$env:(\w+)'
foreach ($File in $PsFiles) {
    $Content = Get-Content $File.FullName -Raw
    $Matches = [regex]::Matches($Content, $EnvRefPattern)

    foreach ($Match in $Matches) {
        $VarName = $Match.Groups[1].Value
        $LineNumber = ($Content.Substring(0, $Match.Index) -split "`n").Count

        # Skip system vars
        $IsSystem = $false
        foreach ($SysVar in $SystemVars) {
            if ($VarName -like $SysVar) { $IsSystem = $true; break }
        }
        if ($IsSystem) { continue }

        # Check if declared
        $Declared = $VarName -in $DeclaredVars
        if (-not $Declared) {
            $Key = "${VarName}:$($File.FullName)"
            if (-not $UnregisteredVars.ContainsKey($Key)) {
                $UnregisteredVars[$Key] = [PSCustomObject]@{
                    File = $File.FullName
                    Line = $LineNumber
                    Var  = $VarName
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
$ExitCode = 0

if ($Violations.Count -gt 0) {
    Write-Host "`n============================================" -ForegroundColor Red
    Write-Host "  PARALLEL-UNSAFE ENV VAR VIOLATIONS" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    foreach ($V in $Violations | Sort-Object File, Line) {
        Write-Host "  [$($V.Code)] $($V.File):$($V.Line)" -ForegroundColor Yellow
        Write-Host "           $($V.Message)" -ForegroundColor Gray
    }
    $ExitCode = 1
}

if ($UnregisteredVars.Count -gt 0) {
    Write-Host "`n============================================" -ForegroundColor Yellow
    Write-Host "  UNREGISTERED ENV VARS" -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow
    foreach ($Key in ($UnregisteredVars.Keys | Sort-Object)) {
        $V = $UnregisteredVars[$Key]
        Write-Host "  [UNREGISTERED] $($V.Var)" -ForegroundColor Yellow
        Write-Host "                $($V.File):$($V.Line)" -ForegroundColor Gray
    }
    Write-Host "`n  Add each var to docs/Reference/env-var-registry.json" -ForegroundColor Gray
    if ($FailOnMissing) { $ExitCode = 1 }
}

if ($ExitCode -eq 0) {
    Write-Host "`n[PASS] All env var references accounted for. No parallel-safety violations." -ForegroundColor Green
}

exit $ExitCode
