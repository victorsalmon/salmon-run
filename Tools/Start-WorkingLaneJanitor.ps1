#Requires -Version 7.0
<#
.SYNOPSIS
    Sweeps stale Salmon Run working lanes and transitions any that have
    completed or failed while the main pond engine is busy on another pond.
.DESCRIPTION
    The pond engine processes one lane at a time and the Monitor task blocks
    until the subprocess exits.  If a previous lane's process died without being
    transitioned, this janitor runs independently, moves the plan files to the
    correct next queue, and commits/pushes the task repo.
.PARAMETER TaskRoot
    Root of the Salmon task queue (usually ~/.salmon/Tasks).
.PARAMETER RepoDir
    Path to the Salmon Run repository that contains the SalmonRun.PondEngine module.
.PARAMETER ConfigPath
    Optional path to an orchestrator config JSON with namespaceRepoMap.
#>
[CmdletBinding()]
param(
    [string]$TaskRoot = 'C:\\Users\\RDP\\.salmon\\Tasks',
    [string]$RepoDir = 'C:\\Repos\\Public\\Salmon-Run',
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Continue'

$moduleLoader = if ($RepoDir) { Join-Path $RepoDir 'Modules' 'SalmonRun.ModuleLoader' 'Public' 'Initialize-InterclawEnvironment.ps1' } else { $null }
if (-not ($moduleLoader -and (Test-Path -LiteralPath $moduleLoader))) {
    $moduleLoader = (Resolve-Path 'C:\Repos\Public\Salmon-Run\Modules\SalmonRun.ModuleLoader\Public\Initialize-InterclawEnvironment.ps1' -ErrorAction SilentlyContinue)?.Path
}
if (-not (Test-Path -LiteralPath $moduleLoader)) {
    throw "Start-WorkingLaneJanitor: module loader not found at $moduleLoader"
}
. $moduleLoader
if ([string]::IsNullOrWhiteSpace($RepoDir)) { $RepoDir = Get-SalmonRunRepoRoot }
$null = Initialize-InterclawEnvironment -RepoRoot $RepoDir
if ([string]::IsNullOrWhiteSpace($TaskRoot)) { $TaskRoot = Get-SalmonTaskRoot }

$moduleBase = Join-Path $RepoDir 'Modules' 'SalmonRun.PondEngine'
$module = Get-Module -Name 'SalmonRun.PondEngine' -ErrorAction SilentlyContinue
if (-not $module) {
    Import-Module (Join-Path $moduleBase 'SalmonRun.PondEngine.psd1') -Force -ErrorAction Stop
    $module = Get-Module -Name 'SalmonRun.PondEngine' -ErrorAction Stop
}

# Dot-source the transition and push helpers so this out-of-module script can
# call the module's internal transition logic directly.
$privatePath = Join-Path $moduleBase 'Private'
foreach ($helper in @('PondTasks\Invoke-PondTaskTransition.ps1', 'PondTasks\Push-PondRepos.ps1')) {
    $hp = Join-Path $privatePath $helper
    if (Test-Path -LiteralPath $hp) { . $hp }
}

# Build the same namespace-to-repo map the engine uses.
$mergedMap = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
$salmonConfig = if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
    $ConfigPath
} else {
    Join-Path (Get-SalmonHome) 'orchestrator.config.json'
}
if (Test-Path -LiteralPath $salmonConfig) {
    $cfg = Get-Content -LiteralPath $salmonConfig -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -AsHashtable -ErrorAction SilentlyContinue
    if ($cfg -and $cfg['namespaceRepoMap']) {
        foreach ($k in $cfg['namespaceRepoMap'].Keys) {
            $mergedMap[$k] = $cfg['namespaceRepoMap'][$k]
        }
    }
}

# Ponds are needed to resolve OnSuccess/OnFailure and role names.
$ponds = & $module { Get-SalmonRunPonds }

$workingDir = Join-Path $TaskRoot 'Working'
if (-not (Test-Path -LiteralPath $workingDir)) {
    Write-Verbose "Start-WorkingLaneJanitor: no Working directory"
    return
}

$lanes = Get-ChildItem -LiteralPath $workingDir -Directory -ErrorAction SilentlyContinue
if (-not $lanes) { return }

$moved = 0
foreach ($lane in $lanes) {
    $lanePath = $lane.FullName
    $completeFile = Join-Path $lanePath '.complete'
    $failedFile = Join-Path $lanePath '.failed'
    $hasComplete = Test-Path -LiteralPath $completeFile
    $hasFailed = Test-Path -LiteralPath $failedFile

    if (-not $hasComplete -and -not $hasFailed) { continue }

    # If the recorded process is still alive, the main Monitor is still running.
    $pidFile = Join-Path $lanePath '.pid'
    $alive = $false
    if (Test-Path -LiteralPath $pidFile) {
        $pidText = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
        $lanePid = $null
        if ([int]::TryParse($pidText, [ref]$lanePid)) {
            try { $alive = (Get-Process -Id $lanePid -ErrorAction SilentlyContinue) -ne $null } catch { $alive = $false }
        }
    }
    if ($alive) { continue }

    # Determine which pond this lane belongs to.
    $spawnFile = Join-Path $lanePath '.spawn'
    $pondName = $null
    if (Test-Path -LiteralPath $spawnFile) {
        try {
            $spawn = Get-Content -LiteralPath $spawnFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $pondName = $spawn.Pond
        } catch {
            Write-Verbose "Start-WorkingLaneJanitor: cannot parse .spawn for $lanePath"
        }
    }

    # Fall back to the lane name prefix if .spawn is missing or unparseable.
    if ([string]::IsNullOrWhiteSpace($pondName)) {
        if ($lane.Name -like 'lane-coder-*') { $pondName = 'Code' }
        elseif ($lane.Name -like 'lane-reviewer-*') { $pondName = 'Review' }
        elseif ($lane.Name -like 'lane-auditor-*') { $pondName = 'Audit' }
        elseif ($lane.Name -like 'lane-qa-*') { $pondName = 'QA' }
        elseif ($lane.Name -like 'lane-project-*') { $pondName = 'ProjectReview' }
    }

    $pond = $ponds | Where-Object { $_.Name -eq $pondName } | Select-Object -First 1
    if (-not $pond) {
        Write-Warning "Start-WorkingLaneJanitor: cannot resolve pond for $lanePath"
        continue
    }

    $planFiles = @(Get-ChildItem -Path "$lanePath/*.md" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($planFiles.Count -eq 0) { continue }

    $ns = ''
    if ($planFiles[0].Name -match '^\d{4}[-.]?\d{2}[-.]?\d{2}[-.]([^-]+)') {
        $ns = $Matches[1]
    }

    $group = [PondGroup]::new()
    $group.Namespace = $ns
    $group.Role = $pond.Role
    $group.Files = $planFiles
    $group.StreamPath = $lanePath

    $repoPath = $null
    $planContent = Get-Content -LiteralPath $planFiles[0].FullName -Raw -ErrorAction SilentlyContinue
    $m = [regex]::Match($planContent, '(?im)^\*\*(TargetRepo|Target|Repo)\*\*:\s*(?<value>[^\r\n]+)')
    if ($m.Success) {
        $raw = $m.Groups['value'].Value.Trim()
        if (-not ($raw -in @('n/a', 'none'))) {
            $repoPath = $raw -replace '\s*\([^)]*\)\s*$', ''
            if (-not ($repoPath -match '[/\\\\:]' -or $repoPath -match '\.(git|ca|com)$')) {
                if ($mergedMap.ContainsKey($repoPath)) {
                    $repoPath = $mergedMap[$repoPath]
                } elseif ($mergedMap.ContainsKey($ns)) {
                    $repoPath = $mergedMap[$ns]
                }
            }
            if (-not [System.IO.Path]::IsPathRooted($repoPath) -and $mergedMap.ContainsKey($ns)) {
                $repoPath = $mergedMap[$ns]
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -ErrorAction SilentlyContinue)) {
        if ($mergedMap.ContainsKey($ns)) { $repoPath = $mergedMap[$ns] }
    }
    if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath (Join-Path $repoPath '.git') -ErrorAction SilentlyContinue)) {
        $repoPath = $RepoDir
    }
    $group.RepoPath = $repoPath

    $context = [PondContext]::new()
    $context.TaskRoot = $TaskRoot
    $context.RepoDir = $RepoDir
    $context.CurrentPond = $pond
    $context.CurrentGroup = $group
    $context.Success = $hasComplete
    $context.Continue = $true
    $context.Config = [PSCustomObject]@{ NamespaceRepoMap = $mergedMap; TimeoutMinutes = 30 }

    $task = [PondTask]@{
        Name     = 'Transition'
        Type     = 'Group'
        Function = 'Invoke-PondTaskTransition'
    }

    try {
        $null = Invoke-PondTaskTransition -Pond $pond -Task $task -Context $context
        $moved++
        $dest = if ($context.Success) { $pond.OnSuccess.MoveTo } else { $pond.OnFailure.MoveTo }
        Write-Verbose "Start-WorkingLaneJanitor: transitioned $($planFiles.Count) plan(s) from $lanePath to $dest"
    } catch {
        Write-Warning "Start-WorkingLaneJanitor: transition failed for $lanePath : $_"
    }
}

if ($moved -gt 0) {
    Write-Verbose "Start-WorkingLaneJanitor: moved $moved working lane(s)"
}
