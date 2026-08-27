# Get-SalmonConfig.ps1 — resolve ~/.salmon/ configuration for audit terminal plans
# Precedence: $HOME/.salmon/ (machine-specific) > <repo>/.salmon/ (public-repo) > built-in defaults
# Usage:
#   $cfg = & (Resolve-Path "Skills/Auditor/Get-SalmonConfig.ps1") -PlanName "redeploy"
#   $cfg = & (Resolve-Path "Skills/Auditor/Get-SalmonConfig.ps1") -PlanName "post-audit-fixes"
# Returns a PSCustomObject parsed from JSON. Never throws when config is missing — returns $null and caller falls back to built-ins.

param(
    [Parameter(Mandatory)]
    [ValidateSet("redeploy", "post-audit-fixes")]
    [string]$PlanName,

    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
)

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warning "Get-SalmonConfig: failed to parse $Path — $($_.Exception.Message)"
        return $null
    }
}

# 1. Machine-specific: $HOME/.salmon/audit/<plan>.json  (also checks $env:USERPROFILE for Windows compat)
$homeCandidates = @()
if ($env:HOME) { $homeCandidates += (Join-Path $env:HOME ".salmon/audit/$PlanName.json") }
if ($env:USERPROFILE) { $homeCandidates += (Join-Path $env:USERPROFILE ".salmon/audit/$PlanName.json") }
# Expand ~ explicitly for pwsh on Windows
$homeCandidates += (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".salmon/audit/$PlanName.json")
$homeCandidates = $homeCandidates | Select-Object -Unique

foreach ($p in $homeCandidates) {
    $cfg = Read-JsonSafe $p
    if ($null -ne $cfg) {
        Write-Verbose "Get-SalmonConfig: using machine config $p"
        # Tag source for debugging/audit log
        $cfg | Add-Member -NotePropertyName "_source" -NotePropertyValue $p -Force
        return $cfg
    }
}

# 2. Public-repo: <repo>/.salmon/audit/<plan>.json  (checked into git, shared)
$repoPath = Join-Path $RepoRoot ".salmon/audit/$PlanName.json"
$cfg = Read-JsonSafe $repoPath
if ($null -ne $cfg) {
    Write-Verbose "Get-SalmonConfig: using repo config $repoPath"
    $cfg | Add-Member -NotePropertyName "_source" -NotePropertyValue $repoPath -Force
    return $cfg
}

# 3. Built-in fallback: <repo>/Skills/Auditor/.salmon.defaults/audit/<plan>.json (if present)
$builtinPath = Join-Path $PSScriptRoot ".salmon.defaults/audit/$PlanName.json"
$cfg = Read-JsonSafe $builtinPath
if ($null -ne $cfg) {
    Write-Verbose "Get-SalmonConfig: using built-in defaults $builtinPath"
    $cfg | Add-Member -NotePropertyName "_source" -NotePropertyValue $builtinPath -Force
    return $cfg
}

Write-Verbose "Get-SalmonConfig: no config found for $PlanName — caller should use hard-coded defaults"
return $null
