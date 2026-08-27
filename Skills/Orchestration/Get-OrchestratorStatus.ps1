<#
.SYNOPSIS
    Reports whether the orchestrator and stream agents are running and counts plans by queue.
.DESCRIPTION
    Checks the orchestrator PowerShell process, polls Tasks/Logs/agents/ for live stream agents,
    and counts .md plan files in the standard Tasks/<state>/ queues.
.PARAMETER RepoRoot
    Root of the repo worktree. Defaults to the script's grandparent.
.PARAMETER AsJson
    Emit the result as JSON instead of a human-readable report.
.EXAMPLE
    .\Skills\\Orchestration\Get-OrchestratorStatus.ps1
.EXAMPLE
    .\Skills\\Orchestration\Get-OrchestratorStatus.ps1 -RepoRoot C:\repos\intersite-orchestrator-worktrees\stream-2 -AsJson
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")),
    [switch]$AsJson
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path $RepoRoot
$agentDir = Join-Path $RepoRoot "Tasks\Logs\agents"

# --- Orchestrator process detection ---
$orchestratorKeywords = @('LocalOrchestrator.ps1', 'Invoke-Orchestrate.ps1', 'Start-Orchestrator')
$orchestratorProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $cmd = $_.CommandLine
    foreach ($kw in $orchestratorKeywords) { if ($cmd -like "*$kw*") { return $true } }
    return $false
}

$orchestratorRunning = [bool]$orchestratorProcs
$orchestratorPids = $orchestratorProcs | Select-Object -ExpandProperty ProcessId

# --- Stream agents ---
$monitorScript = Join-Path $PSScriptRoot "Invoke-MonitorSubagents.ps1"
$agents = @()
if (Test-Path $monitorScript) {
    $agents = & $monitorScript -RepoRoot $RepoRoot -PassThru
}
$runningAgents = @($agents | Where-Object { $_.IsAlive }).Count
$staleAgents = @($agents | Where-Object { -not $_.IsAlive }).Count

# --- Plan counts ---
$stateMap = [ordered]@{
    Working  = 'working'
    Code     = 'code'
    Review   = 'review'
    Complete = 'complete'
    Failed   = 'failed'
    Paused   = 'paused'
    Manual   = 'manual'
}
$planCounts = [ordered]@{}
$missingDirs = [System.Collections.Generic.List[string]]::new()
foreach ($dirName in $stateMap.Keys) {
    $dir = Join-Path $RepoRoot "Tasks\$dirName"
    if (Test-Path $dir) {
        $count = (Get-ChildItem -Path $dir -Filter "*.md" -Recurse -File | Where-Object { $_.Name -ne '.gitkeep' }).Count
    } else {
        $count = 0
        $missingDirs.Add($dirName)
    }
    $planCounts[$stateMap[$dirName]] = $count
}

# Supplemental: capture ToDo if it exists
$todoDir = Join-Path $RepoRoot "Tasks\ToDo"
if (Test-Path $todoDir) {
    $todoCount = (Get-ChildItem -Path $todoDir -Filter "*.md" -Recurse -File | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $planCounts['todo'] = $todoCount
}

if ($AsJson) {
    return [PSCustomObject]@{
        RepoRoot            = $RepoRoot.Path
        OrchestratorRunning = $orchestratorRunning
        OrchestratorPids    = @($orchestratorPids)
        StreamAgentsRunning = $runningAgents
        StreamAgentsStale   = $staleAgents
        Agents              = @($agents)
        Plans               = $planCounts
        MissingDirectories  = @($missingDirs)
    } | ConvertTo-Json -Depth 4
}

# --- Human-readable output ---
Write-Host "Orchestrator Status  ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Cyan
Write-Host "".PadRight(50, '-')
$orchColor = if ($orchestratorRunning) { 'Green' } else { 'Red' }
Write-Host "Orchestrator running: $(if ($orchestratorRunning) { 'YES' } else { 'NO' })" -ForegroundColor $orchColor
if ($orchestratorRunning) {
    Write-Host "  PIDs: $($orchestratorPids -join ', ')" -ForegroundColor Gray
}
$agentColor = if ($runningAgents -gt 0) { 'Green' } else { 'Yellow' }
Write-Host "Stream agents running: $runningAgents (stale: $staleAgents)" -ForegroundColor $agentColor
if ($agents) {
    foreach ($a in $agents) {
        $status = if ($a.IsAlive) { 'running' } else { 'stale' }
        $color = if ($a.IsAlive) { 'Green' } else { 'Red' }
        Write-Host "  - $($a.AgentId) [$($a.Role)] PID $($a.Pid) ($status)" -ForegroundColor $color
    }
}
Write-Host ""
Write-Host "Plan counts" -ForegroundColor Yellow
foreach ($key in $planCounts.Keys) {
    Write-Host "  $($key.PadRight(10)): $($planCounts[$key])" -ForegroundColor Gray
}
if ($missingDirs.Count -gt 0) {
    Write-Host ""
    Write-Host "Missing directories (counted as 0): $($missingDirs -join ', ')" -ForegroundColor DarkGray
}
