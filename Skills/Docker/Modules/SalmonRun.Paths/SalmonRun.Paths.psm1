#Requires -Version 7.0
Set-StrictMode -Off

$script:CachedRepoRoot = $null
$script:CachedHomeDir = $null
# Thread safety: cached values are idempotent (all threads compute the same value).
# The race window is benign ΓÇö stale reads produce correct results, double writes
# set the same value. Not suitable for ForEach-Object -Parallel where $script:
# scope is per-runspace (each runspace gets its own cached value).

<#
.SYNOPSIS
    Returns the home directory from env var or platform default.
.OUTPUTS
    System.String
#>
function Get-HomeDir {
    if ($script:CachedHomeDir) { return $script:CachedHomeDir }

    if (-not [string]::IsNullOrWhiteSpace($env:INTERCLAW_HOME)) {
        $script:CachedHomeDir = $env:INTERCLAW_HOME
        return $script:CachedHomeDir
    }

    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $result = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { "C:\Users\node" }
    } else {
        $result = if (-not [string]::IsNullOrWhiteSpace($env:HOME)) { $env:HOME } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { "/home/node" }
    }
    $script:CachedHomeDir = $result
    return $result
}

<#
.SYNOPSIS
    Returns the repository root directory by walking up from the module path.
.OUTPUTS
    System.String
#>
function Get-RepoRoot {
    if ($script:CachedRepoRoot) { return $script:CachedRepoRoot }
    $dir = Split-Path $PSScriptRoot -Parent
    $dir = Split-Path $dir -Parent
    if (-not (Test-Path (Join-Path $dir ".git"))) {
        $dir = $env:REPO_ROOT
        if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-SalmonRunRepoRoot }
    }
    $script:CachedRepoRoot = $dir
    return $dir
}

<#
.SYNOPSIS
    Returns the SalmonRun repo root by walking up from PSScriptRoot looking for AGENTS.md or .git.
.OUTPUTS
    System.String
#>
function Get-SalmonRunRepoRoot {
    if ($script:CachedRepoRoot) { return $script:CachedRepoRoot }
    if (-not [string]::IsNullOrWhiteSpace($env:REPO_ROOT)) { $script:CachedRepoRoot = $env:REPO_ROOT; return $script:CachedRepoRoot }
    $ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PSScriptRoot }
    if (-not $ScriptRoot) { $script:CachedRepoRoot = (Get-Location).Path; return $script:CachedRepoRoot }
    $Current = $ScriptRoot
    while ($Current -and -not (
        (Test-Path (Join-Path $Current "AGENTS.md") -PathType Leaf) -or
        (Test-Path (Join-Path $Current ".git") -PathType Container)
    )) {
        $Parent = Split-Path $Current -Parent
        if ($Parent -eq $Current) { break }
        $Current = $Parent
    }
    if ([string]::IsNullOrWhiteSpace($Current) -or $Current -eq "/" -or -not (Test-Path (Join-Path $Current "Skills" "Docker") -PathType Container -ErrorAction SilentlyContinue)) {
        $fromEnv = if (-not [string]::IsNullOrWhiteSpace($env:REPO_ROOT)) { $env:REPO_ROOT } else { $env:REPO_DIR }
        if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { $Current = $fromEnv }
    }
    $script:CachedRepoRoot = $Current
    return $Current
}

<#
.SYNOPSIS
    Clears cached path values so subsequent calls re-resolve from source.
#>
function Get-SkillsRoot {
    [CmdletBinding()]
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-SalmonRunRepoRoot }
    $candidates = @(
        (Join-Path $RepoRoot 'Skills'),
        (Join-Path (Split-Path $RepoRoot -Parent) 'Skills')
    )
    foreach ($c in $candidates) {
        if (Test-Path $c -PathType Container) { return $c }
    }
    return $candidates[0]
}

function Resolve-SkillPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$RepoRoot
    )
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Get-SalmonRunRepoRoot }
    foreach ($root in @($RepoRoot, (Split-Path $RepoRoot -Parent))) {
        $full = Join-Path $root $RelativePath
        if (Test-Path $full) { return $full }
    }
    return $null
}

function Reset-SalmonRunPathCache {
    $script:CachedRepoRoot = $null
    $script:CachedHomeDir = $null
}

Set-Alias -Name 'Get-InterclawRepoRoot' -Value 'Get-SalmonRunRepoRoot'
Set-Alias -Name 'Reset-InterclawPathCache' -Value 'Reset-SalmonRunPathCache'

Export-ModuleMember -Function 'Get-SalmonRunRepoRoot','Get-HomeDir','Get-RepoRoot','Get-SkillsRoot','Resolve-SkillPath','Reset-SalmonRunPathCache' -Alias 'Get-InterclawRepoRoot','Reset-InterclawPathCache'
