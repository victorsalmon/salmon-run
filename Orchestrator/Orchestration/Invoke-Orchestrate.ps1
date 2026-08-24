<#
.SYNOPSIS
    Launches a local orchestrator in detached mode, then enters a persistent
    watchdog loop that monitors queues, detects crashes, re-launches, and
    reports success when all three queues are empty.
.DESCRIPTION
    Spawns LocalOrchestrator.ps1 with -Detach -NoAuditPrompt, then enters a
    watchdog cycle (default every 5 minutes) that:
      - Checks orchestrator health (PID lock file)
      - Checks agent health (PID/heartbeat files)
      - Checks all three queue counts (Code, Review, Working)
      - Re-launches orchestrator on crash (orphan rescue + re-dispatch)
      - Cleans stale agents
      - Detects no-progress stalls
      - Reports success when orchestrator exits AND all queues empty
.PARAMETER CodeParallelCount
    Pass through to LocalOrchestrator.ps1 -CodeParallelCount.
.PARAMETER ReviewerParallelCount
    Pass through to LocalOrchestrator.ps1 -ReviewerParallelCount.
.PARAMETER MaxRuntimeMinutes
    Pass through to LocalOrchestrator.ps1 -MaxRuntimeMinutes.
.PARAMETER PollIntervalSeconds
    Pass through to LocalOrchestrator.ps1 -PollIntervalSeconds.
.PARAMETER IdleTimeoutMinutes
    Pass through to LocalOrchestrator.ps1 -IdleTimeoutMinutes.
.PARAMETER WatchIntervalSeconds
    Seconds between watchdog health checks. Default 300 (5 min).
.PARAMETER MaxWatchMinutes
    Maximum minutes for watchdog to keep checking. 0 = unlimited. Default 0.
.PARAMETER DetachWatchdog
    If set, re-launches the entire watchdog in a hidden PowerShell window
    and exits. The detached watchdog monitors the orchestrator and reports
    via the queue state. Use for RunFix or background dispatch.
#>

param(
    [ValidateSet("opencode", "devin", "deepseek", "codex")]
    [string]$Harness = $env:OC_HARNESS,
    [string]$Provider = $env:OC_PROVIDER,
    [string]$Model = $env:OC_MODEL,
    [string]$Effort = $env:OC_EFFORT,
    [ValidateSet("local", "local-platform", "platform")]
    [string]$Executor = "local",
    [int]$CodeParallelCount = 9,
    [int]$ReviewerParallelCount = 3,
    [int]$MaxRuntimeMinutes,
    [int]$PollIntervalSeconds,
    [int]$IdleTimeoutMinutes,
    [ValidateRange(30, 3600)]
    [int]$WatchIntervalSeconds = 300,
    [ValidateRange(0, 1440)]
    [int]$MaxWatchMinutes = 0,
    [ValidateRange(1, 100)]
    [int]$MaxAgentCount = 16,
    [ValidateRange(0, 10)]
    [int]$ModuleCount = 1,
    [switch]$FinishWithAudit,
    [switch]$DetachWatchdog
)
# Local safe PID parser — returns [int] for valid positive integers, $null otherwise
function Convert-PidSafe {
    param([string]$Value)
    $pidNum = 0
    if (-not [string]::IsNullOrWhiteSpace($Value) -and [int]::TryParse($Value.Trim(), [ref]$pidNum) -and $pidNum -gt 0) {
        return $pidNum
    }
    return $null
}

$RepoDir = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LogDir = "$RepoDir/Tasks/Logs"
$AgentDir = "$LogDir/agents"
$WorkingDir = "$RepoDir/Tasks/Working"
# Scan for the latest instance-qualified PID file (or fall back to legacy)
function Get-OrchestratorPidFile {
    $candidates = Get-ChildItem "$LogDir\.orchestrator-*-pid" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($candidates -and $candidates[0]) { return $candidates[0].FullName }
    return $null
}

function Get-OpencodePath {
    $opencodeCmd = Get-Command opencode.ps1 -ErrorAction SilentlyContinue
    if (-not $opencodeCmd) { $opencodeCmd = Get-Command opencode -ErrorAction SilentlyContinue }
    if (-not $opencodeCmd) { $opencodeCmd = Get-Command opencode.exe -ErrorAction SilentlyContinue }
    if (-not $opencodeCmd) {
        $commonPaths = @(
            "$env:APPDATA\npm\opencode.ps1",
            "$env:APPDATA\npm\opencode",
            "$env:LOCALAPPDATA\opencode\opencode.ps1",
            "$env:LOCALAPPDATA\opencode\opencode.exe",
            "$env:LOCALAPPDATA\opencode\opencode.cmd",
            "$env:APPDATA\npm\opencode.cmd",
            "$env:ProgramFiles\nodejs\opencode.cmd",
            "$env:USERPROFILE\.opencode\bin\opencode.ps1",
            "$env:USERPROFILE\.opencode\bin\opencode"
        )
        foreach ($p in $commonPaths) {
            if (Test-Path $p) {
                $opencodeCmd = Get-Command $p -ErrorAction SilentlyContinue
                if ($opencodeCmd) { break }
            }
        }
    }
    if (-not $opencodeCmd) { return $null }
    return $opencodeCmd.Source
}

function Initialize-OpenCodeEnvironment {
    <#
    .SYNOPSIS
        Gives a standalone OpenCode installation writable, isolated XDG state.

    OpenCode's worker is launched from a hidden PowerShell process.  When the
    CLI is installed under Tools/opencode-standalone, its default state path
    can resolve into a locked profile directory instead of the installation's
    writable runtime area.  That produces an apparently valid model selection
    followed by an executor failure before a request can complete.
    #>
    if ($Harness -ne 'opencode') { return }
    $configured = [string]$env:OPENCODE_CLI_PATH
    if ([string]::IsNullOrWhiteSpace($configured)) { return }
    try { $resolved = (Resolve-Path -LiteralPath $configured -ErrorAction Stop).Path } catch { return }
    if ($resolved -notmatch '\\node_modules\\\.bin\\opencode\.(ps1|cmd)$') { return }

    $standaloneRoot = Split-Path (Split-Path (Split-Path $resolved -Parent) -Parent) -Parent
    $toolsRoot = Split-Path $standaloneRoot -Parent
    $xdgRoots = @{
        XDG_CONFIG_HOME = Join-Path $toolsRoot 'opencode-config'
        XDG_DATA_HOME   = Join-Path $toolsRoot 'opencode-data'
        XDG_STATE_HOME  = Join-Path $toolsRoot 'opencode-state'
        XDG_CACHE_HOME  = Join-Path $toolsRoot 'opencode-cache'
    }
    foreach ($entry in $xdgRoots.GetEnumerator()) {
        $null = New-Item -ItemType Directory -Path $entry.Value -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $entry.Value) {
            Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
        }
    }
    Write-WatchdogLog "OPENCODE_ENV_READY cli='$resolved' config='$($env:XDG_CONFIG_HOME)' data='$($env:XDG_DATA_HOME)' state='$($env:XDG_STATE_HOME)'"
}

function Start-CompleteAudit {
    param([string]$RepoDir, [string]$LogDir)
    $opencodePath = Get-OpencodePath
    if (-not $opencodePath) {
        Write-WatchdogLog "AUDIT_LAUNCH_FAILED reason='opencode CLI not found'" -Level ERROR
        return $null
    }
    $agentDir = Join-Path $LogDir "agents"
    $null = New-Item -ItemType Directory -Path $agentDir -Force
    $stdOut = Join-Path $agentDir "audit-complete-$PID.stdout"
    $stdErr = Join-Path $agentDir "audit-complete-$PID.stderr"
    $pwsh = (Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    if (-not $pwsh) { $pwsh = 'pwsh' }
    $proc = Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoProfile', '-NoLogo', '-File', $opencodePath, 'run', '--command', 'audit-complete') `
        -WorkingDirectory $RepoDir `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $stdOut `
        -RedirectStandardError $stdErr
    Write-WatchdogLog "AUDIT_LAUNCHED pid=$($proc.Id) opencode='$opencodePath'"
    return $proc
}

function Show-PostWorkCompleteChecklist {
    <#
    .SYNOPSIS
        Interactive "post work complete" checklist for unresolved Manual/Failed plans.
        Called by the watchdog when Code, Review and Working are empty but Manual or
        Failed items remain. Returns $true when the user wants to exit, $false to
        resume polling. Exits automatically if new work appears.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RepoDir
    )

    # Guard: only run in an actual console.  Hidden/headless watchdogs skip this.
    $consoleAvailable = $false
    try { $consoleAvailable = ($Host.Name -eq 'ConsoleHost') -and [Console]::KeyAvailable } catch { $consoleAvailable = $false }
    if (-not $consoleAvailable) {
        Write-WatchdogLog "POST_WORK_CHECKLIST_SKIPPED reason='no interactive console' host=$($Host.Name)"
        return $true
    }

    $manualDir = Join-Path $RepoDir 'Tasks/Manual'
    $failedDir = Join-Path $RepoDir 'Tasks/Failed'
    $manualFiles = @(Get-ChildItem "$manualDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $failedFiles = @(Get-ChildItem "$failedDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    if (($manualFiles.Count + $failedFiles.Count) -eq 0) {
        return $true
    }

    $items = @()
    foreach ($f in $manualFiles) { $items += @{ File = $f; Type = 'Manual' } }
    foreach ($f in $failedFiles) { $items += @{ File = $f; Type = 'Failed' } }

    function Get-PlanSummary($planPath) {
        $content = Get-Content $planPath -Raw -ErrorAction SilentlyContinue
        $title = if ($content -match '(?m)^#\s+(.*)$') { $Matches[1].Trim() } else { Split-Path $planPath -Leaf }

        # Find the most descriptive reason block
        $reason = ''
        $patterns = @(
            '##\s*What needs \(user action\)', '##\s*Unblock options',
            '##\s*Action required', '##\s*Proposed fix',
            '##\s*Why deferred', '##\s*Root cause',
            '##\s*Problem', '##\s*What happened',
            '##\s*Why it happens', '##\s*Blocker'
        )
        foreach ($p in $patterns) {
            if ($content -match "(?ms)\Q$p\E\r?\n(.*?)(?=^##\s|\z)") {
                $block = $Matches[1].Trim() -replace '\r?\n+', ' ' -replace '\s+', ' '
                if ($block) {
                    if ($block.Length -gt 240) { $block = $block.Substring(0, 240) + '...' }
                    $reason = $block
                    break
                }
            }
        }
        if (-not $reason) {
            $lines = $content -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 5
            $reason = ($lines -join ' ').Trim()
            if ($reason.Length -gt 240) { $reason = $reason.Substring(0, 240) + '...' }
        }
        return @{ Title = $title; Reason = $reason }
    }

    function Render-Checklist($items, $message = '') {
        try { Clear-Host } catch { Write-WatchdogLog "CLEAR_HOST_FAILED error='$($_.Exception.Message)'" -Level DEBUG }
        Write-Host "╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║        POST WORK COMPLETE — Manual / Failed checklist             ║" -ForegroundColor Cyan
        Write-Host "╠════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $it = $items[$i]
            $num = $i + 1
            $sum = Get-PlanSummary -planPath $it.File.FullName
            $color = if ($it.Type -eq 'Failed') { 'Red' } else { 'Yellow' }
            Write-Host "[$num] $($it.Type): $($sum.Title)" -ForegroundColor $color
            Write-Host "    $($sum.Reason)" -ForegroundColor DarkGray
        }
        Write-Host "╠════════════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "  <n> c  = move item n to Tasks/Code (as a ready session plan)" -ForegroundColor Cyan
        Write-Host "  <n> h  = keep in Tasks/Manual or Tasks/Failed (human-required)" -ForegroundColor Cyan
        Write-Host "  <n> a  = archive item to Tasks/Archive/<Manual|Failed>/" -ForegroundColor Cyan
        Write-Host "  <n> s  = skip / no decision yet" -ForegroundColor Cyan
        Write-Host "  q    = finish and exit watchdog" -ForegroundColor Cyan
        Write-Host "  Enter  = continue waiting; new material in Code/Review/Working resumes" -ForegroundColor Cyan
        Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        if ($message) {
            Write-Host $message -ForegroundColor Green
        }
        Write-Host "> " -NoNewline -ForegroundColor Cyan
    }

    function Move-ToArchive($source, $type) {
        $archiveBase = Join-Path $RepoDir "Tasks/Archive/$type"
        $null = New-Item -ItemType Directory -Path $archiveBase -Force -ErrorAction SilentlyContinue
        $dest = Join-Path $archiveBase $source.Name
        $counter = 1
        while (Test-Path $dest) {
            $base = [IO.Path]::GetFileNameWithoutExtension($source.Name)
            $ext = [IO.Path]::GetExtension($source.Name)
            $dest = Join-Path $archiveBase "$base-$counter$ext"
            $counter++
        }
        Move-Item -LiteralPath $source.FullName -Destination $dest -Force
        return $dest
    }

    function Move-ToCode($source) {
        $codeDir = Join-Path $RepoDir 'Tasks/Code'
        $null = New-Item -ItemType Directory -Path $codeDir -Force -ErrorAction SilentlyContinue
        $content = Get-Content $source.FullName -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $content = $content -replace '(?m)^#\s*Manual:?', '# Session Plan'
            if ($content -notmatch '\*\*Status\*\*:\s*ready') {
                $content = "**Status**: ready`r`n`r`n" + $content
            }
            $content | Set-Content -LiteralPath $source.FullName -Encoding utf8 -NoNewline
        }
        $dest = Join-Path $codeDir $source.Name
        $counter = 1
        while (Test-Path $dest) {
            $base = [IO.Path]::GetFileNameWithoutExtension($source.Name)
            $ext = [IO.Path]::GetExtension($source.Name)
            $dest = Join-Path $codeDir "$base-$counter$ext"
            $counter++
        }
        Move-Item -LiteralPath $source.FullName -Destination $dest -Force
        return $dest
    }

    $renderMessage = ''
    Render-Checklist -items $items -message $renderMessage

    $buffer = [System.Text.StringBuilder]::new()
    $lastPoll = [datetime]::MinValue
    $pollInterval = [timespan]::FromSeconds(5)

    while ($true) {
        if ([datetime]::Now - $lastPoll -gt $pollInterval) {
            $counts = $null
            try { $counts = Get-TaskCounts } catch { Write-WatchdogLog "TASK_COUNTS_FAILED error='$($_.Exception.Message)'" -Level WARN }
            if ($counts) {
                $workPresent = ($counts.CoderWorkload -gt 0) -or ($counts.ReviewerWorkload -gt 0) -or ($counts.Working -gt 0)
                if ($workPresent) {
                    Write-WatchdogLog "POST_WORK_RESUME_NEW_WORK code=$($counts.CoderWorkload) review=$($counts.ReviewerWorkload) working=$($counts.Working)"
                    return $false
                }
            }
            $lastPoll = [datetime]::Now
        }

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)

            if ($key.Key -eq [ConsoleKey]::Enter) {
                $input = $buffer.ToString().Trim()
                $buffer = [System.Text.StringBuilder]::new()
                if (-not $input) {
                    # blank Enter -> just keep waiting
                    [Console]::Write("`r" + (' ' * 80) + "`r> ")
                    continue
                }

                if ($input -match '^(?i)(q|quit|exit)$') {
                    return $true
                }

                if ($input -match '^(?i)(\d+)\s+([chasd])$') {
                    $num = [int]$Matches[1]
                    $action = $Matches[2].ToLower()
                    if ($num -lt 1 -or $num -gt $items.Count) {
                        $renderMessage = "Invalid item number: $num"
                    } else {
                        $it = $items[$num - 1]
                        try {
                            switch ($action) {
                                'c' {
                                    $newPath = Move-ToCode -source $it.File
                                    $renderMessage = "[$num] routed to Tasks/Code: $(Split-Path $newPath -Leaf)"
                                    Write-WatchdogLog "POST_WORK_ROUTE action=code file=$($it.File.Name) dest=$newPath"
                                }
                                'h' {
                                    $renderMessage = "[$num] remains $($it.Type) / human-required"
                                    Write-WatchdogLog "POST_WORK_ROUTE action=human file=$($it.File.Name)"
                                }
                                'a' {
                                    $type = if ($it.Type -eq 'Failed') { 'Failed' } else { 'Manual' }
                                    $newPath = Move-ToArchive -source $it.File -type $type
                                    $renderMessage = "[$num] archived: $(Split-Path $newPath -Leaf)"
                                    Write-WatchdogLog "POST_WORK_ROUTE action=archive file=$($it.File.Name) dest=$newPath"
                                }
                                's' {
                                    $renderMessage = "[$num] skipped for now"
                                    Write-WatchdogLog "POST_WORK_ROUTE action=skip file=$($it.File.Name)"
                                }
                            }
                        } catch {
                            $renderMessage = "Error routing [$num]: $($_.Exception.Message)"
                            Write-WatchdogLog "POST_WORK_ROUTE_ERROR action=$action file=$($it.File.Name) error='$($_.Exception.Message)'" -Level WARN
                        }
                    }
                    # Refresh the item list in case an item was moved
                    $manualFiles = @(Get-ChildItem "$manualDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
                    $failedFiles = @(Get-ChildItem "$failedDir/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
                    $items = @()
                    foreach ($f in $manualFiles) { $items += @{ File = $f; Type = 'Manual' } }
                    foreach ($f in $failedFiles) { $items += @{ File = $f; Type = 'Failed' } }
                    if ($items.Count -eq 0) {
                        return $true
                    }
                    Render-Checklist -items $items -message $renderMessage
                } else {
                    $renderMessage = "Unrecognized command: '$input'. Use '<n> c|h|a|s' or 'q'."
                    Render-Checklist -items $items -message $renderMessage
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::Escape) {
                return $true
            }

            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) {
                    $null = $buffer.Remove($buffer.Length - 1, 1)
                    [Console]::Write("`b `b")
                }
                continue
            }

            if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) {
                $null = $buffer.Append($key.KeyChar)
                [Console]::Write($key.KeyChar)
            }
        }

        Start-Sleep -Milliseconds 100
    }
}

$detectedPidFile = Get-OrchestratorPidFile
$PidLockFile = if ($detectedPidFile) { $detectedPidFile } else { Join-Path $LogDir ".orchestrator-pid" }
$HbFile = Join-Path $LogDir ".orchestrator-heartbeat"
$WatchdogPidFile = Join-Path $LogDir ".orchestrate-watchdog-pid"
. (Join-Path $PSScriptRoot 'Get-OrchestratorProgressHealth.ps1')

# ─── Watchdog log file + helper (defined early for detach mode) ────
$WatchdogLogFile = Join-Path $LogDir "orchestrate-watchdog-$PID.log"
$WatchdogHeartbeatMaxAgeSeconds = [math]::Max(120, [math]::Min(900, ($WatchIntervalSeconds * 3)))

function Get-WatchdogHealth {
    param(
        [string]$PidPath = $WatchdogPidFile,
        [string]$HeartbeatPath = $null,
        [int]$MaxHeartbeatAgeSeconds = $WatchdogHeartbeatMaxAgeSeconds
    )
    if (-not $HeartbeatPath) { $HeartbeatPath = Join-Path $AgentDir "watchdog-$((Get-Content $PidPath -Raw -ErrorAction SilentlyContinue).Trim()).heartbeat" }
    $pidValue = if (Test-Path -LiteralPath $PidPath) { Convert-PidSafe ((Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue).Trim()) } else { $null }
    $process = if ($pidValue) { Get-Process -Id $pidValue -ErrorAction SilentlyContinue } else { $null }
    $heartbeatAge = $null
    if (Test-Path -LiteralPath $HeartbeatPath) {
        $heartbeatText = (Get-Content -LiteralPath $HeartbeatPath -Raw -ErrorAction SilentlyContinue).Trim()
        $heartbeatDate = $heartbeatText -as [datetime]
        if ($heartbeatDate) { $heartbeatAge = [math]::Round(((Get-Date).ToUniversalTime() - $heartbeatDate.ToUniversalTime()).TotalSeconds) }
    }
    $healthy = $null -ne $process -and $null -ne $heartbeatAge -and $heartbeatAge -ge 0 -and $heartbeatAge -le $MaxHeartbeatAgeSeconds
    [pscustomobject]@{
        Healthy = $healthy
        Reason = if (-not $pidValue) { 'missing-or-invalid-pid' } elseif (-not $process) { 'pid-not-running' } elseif ($null -eq $heartbeatAge) { 'missing-or-invalid-heartbeat' } elseif ($heartbeatAge -gt $MaxHeartbeatAgeSeconds) { 'heartbeat-stale' } else { 'healthy' }
        Pid = $pidValue
        ProcessAlive = $null -ne $process
        HeartbeatAgeSeconds = $heartbeatAge
        MaxHeartbeatAgeSeconds = $MaxHeartbeatAgeSeconds
    }
}

function Write-WatchdogPidMarker {
    param([int]$ProcessId)
    $tmp = "$WatchdogPidFile.$PID.tmp"
    "$ProcessId" | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    Move-Item -LiteralPath $tmp -Destination $WatchdogPidFile -Force
}

function Write-WatchdogLog {
    param([string]$Message, [string]$Level = "INFO")
    $entry = @{
        timestamp = (Get-Date -Format 'o')
        level     = $Level
        pid       = $PID
        watchdog  = $true
        message   = $Message
    } | ConvertTo-Json -Compress
    try { Add-Content -Path $WatchdogLogFile -Value $entry -Encoding utf8 -ErrorAction SilentlyContinue } catch { Write-Host "WATCHDOG_LOG_WRITE_FAILED: $_" -ForegroundColor Red }
}

# The detached watchdog runs outside the orchestrator module session. Load the
# agent-lifecycle module explicitly before the first stale-agent sweep; without
# this, a fresh watchdog exits after calling the otherwise undefined
# Clear-StaleAgentFiles function.
$skillsRoot = Join-Path $RepoDir "Skills"
if (-not (Test-Path $skillsRoot)) { $skillsRoot = Join-Path (Split-Path $RepoDir -Parent) "Skills" }
$moduleRoots = @(
    (Join-Path $RepoDir "Orchestrator/Modules"),
    (Join-Path $skillsRoot "Docker/Modules")
) | Where-Object { Test-Path -LiteralPath $_ }
$orchestratorModules = $moduleRoots | Select-Object -First 1
foreach ($moduleRoot in $moduleRoots) {
    if ($env:PSModulePath -notlike "*$moduleRoot*") {
        $env:PSModulePath = "$moduleRoot$([System.IO.Path]::PathSeparator)$env:PSModulePath"
    }
}
Initialize-OpenCodeEnvironment
if (-not (Get-Command Clear-StaleAgentFiles -ErrorAction SilentlyContinue)) {
    try {
        $env:REPO_ROOT = $RepoDir
        Import-Module (Join-Path $orchestratorModules "Interclaw.AgentLifecycle/Interclaw.AgentLifecycle.psd1") -Force -DisableNameChecking -ErrorAction Stop
    } catch {
        Write-WatchdogLog "AGENT_LIFECYCLE_IMPORT_FAILED error='$($_.Exception.Message)'" -Level WARN
    }
}

# ─── Detach watchdog mode ─────────────────────────────────────────
# Two roles depending on context:
# - First call (no watchdog running): launch hidden watchdog, exit 0.
# - Subsequent calls (watchdog already running): poll queue status, exit
#   0 either way — RunFix checks output for "All queues empty" success pattern
if ($DetachWatchdog) {
    # Check if watchdog already running
    $health = Get-WatchdogHealth
    $existingWDPid = $health.Pid
    $wdAlive = $health.Healthy
    $code   = @(Get-ChildItem (Join-Path $RepoDir "Tasks/Code/*.md") -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $review = @(Get-ChildItem (Join-Path $RepoDir "Tasks/Review/*.md") -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $handoff = @(Get-ChildItem (Join-Path $RepoDir "Tasks/Handoff/*.md") -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $workingDirs = @(Get-ChildItem (Join-Path $RepoDir "Tasks/Working/*") -Directory -ErrorAction SilentlyContinue)
    $working = 0; $workingDirs | ForEach-Object { $working += @(Get-ChildItem "$($_.FullName)/*.md" -File -ErrorAction SilentlyContinue).Count }
    try { $null = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120 -RemoveLogs } catch { Write-WatchdogLog "STALE_AGENT_CLEANUP_ERROR error='$($_.Exception.Message)'" -Level WARN }

    Write-Host "Queues: Code=$code  Review=$review  Handoff=$handoff  Working=$working" -ForegroundColor DarkGray

    # Clear any stop signals from prior crash so RunFix can re-launch cleanly
    foreach ($__sig in @("$RepoDir/Tasks/stop", "$RepoDir/Tasks/stop.code", "$RepoDir/Tasks/stop.review")) {
        if (Test-Path $__sig) { Remove-Item $__sig -Force -ErrorAction SilentlyContinue }
    }

    if (-not $wdAlive) {
        # First call — launch hidden watchdog
        $pwsh = Get-Command pwsh.exe | Select-Object -ExpandProperty Source
        $childCmd = "& '$PSCommandPath'"
        if ($Harness) { $childCmd += " -Harness $Harness" }
        if ($Provider) { $childCmd += " -Provider $Provider" }
        if ($Model) { $childCmd += " -Model $Model" }
        if ($Effort) { $childCmd += " -Effort $Effort" }
        if ($Executor -ne "local") { $childCmd += " -Executor $Executor" }
        if ($CodeParallelCount) { $childCmd += " -CodeParallelCount $CodeParallelCount" }
        if ($ReviewerParallelCount) { $childCmd += " -ReviewerParallelCount $ReviewerParallelCount" }
        if ($MaxRuntimeMinutes) { $childCmd += " -MaxRuntimeMinutes $MaxRuntimeMinutes" }
        if ($PollIntervalSeconds) { $childCmd += " -PollIntervalSeconds $PollIntervalSeconds" }
        if ($IdleTimeoutMinutes) { $childCmd += " -IdleTimeoutMinutes $IdleTimeoutMinutes" }
        if ($WatchIntervalSeconds -ne 180) { $childCmd += " -WatchIntervalSeconds $WatchIntervalSeconds" }
        if ($MaxWatchMinutes) { $childCmd += " -MaxWatchMinutes $MaxWatchMinutes" }
        $childCmd += " -ModuleCount $ModuleCount"
        $childCmd += " -MaxAgentCount $MaxAgentCount"
        if ($FinishWithAudit) { $childCmd += " -FinishWithAudit" }
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($childCmd)
        $encodedCmd = [Convert]::ToBase64String($bytes)
        $stdout = Join-Path $LogDir "watchdog-bootstrap-$PID.stdout"
        $stderr = Join-Path $LogDir "watchdog-bootstrap-$PID.stderr"
        $child = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-EncodedCommand', $encodedCmd) -WorkingDirectory $RepoDir -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        Write-WatchdogPidMarker -ProcessId $child.Id
        Write-Host "Watchdog launched in background (PID $($child.Id)); health will be verified by the next guard cycle" -ForegroundColor Cyan
        Write-Host "Watchdog health before launch: $($health.Reason)" -ForegroundColor DarkGray
        exit 0
    }

    # Check for crash evidence from agent failures
    $lastCrashFile = Join-Path $LogDir ".last-crash-evidence"
    if (Test-Path $lastCrashFile) {
        $crashLines = Get-Content $lastCrashFile -Encoding utf8 -ErrorAction SilentlyContinue
        foreach ($cl in $crashLines) {
            Write-Host "  $cl" -ForegroundColor Red
        }
        # Clear the file after reading so subsequent polls don't re-report the same crashes
        Remove-Item -LiteralPath $lastCrashFile -Force -ErrorAction SilentlyContinue
    }

    # Subsequent call — watchdog is running, check if work is done
    if ($code -eq 0 -and $review -eq 0 -and $working -eq 0) {
        Write-Host "All queues empty — orchestrator complete" -ForegroundColor Green
        exit 0
    }
    Write-Host "Work still in progress (waiting...)" -ForegroundColor Yellow
    exit 0
}

# ─── Single-instance watchdog enforcement (atomic) ─────────────────
$lockFilePath = "$WatchdogPidFile.lock"
try {
    $lockFile = [System.IO.File]::Open($lockFilePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $existingWDPid = if (Test-Path $WatchdogPidFile) { (Get-Content $WatchdogPidFile -Raw -ErrorAction SilentlyContinue).Trim() -as [int] } else { $null }
        if ($existingWDPid -and (Get-Process -Id $existingWDPid -ErrorAction SilentlyContinue) -and $existingWDPid -ne $PID) {
            Write-Host "Another orchestrate watchdog is already running (PID $existingWDPid) — exiting" -ForegroundColor Red
            Write-WatchdogLog "DUPLICATE_INSTANCE existingPid=$existingWDPid" -Level WARN
            exit 1
        }
        # Write directly (avoid Rename-Item cross-drive issues)
        try {
            "$PID" | Out-File -FilePath $WatchdogPidFile -Encoding utf8 -NoNewline -ErrorAction Stop
        } catch {
            Write-WatchdogLog "PID_FILE_WRITE_FAILED error='$($_.Exception.Message)'" -Level WARN
            Write-Host "  ⚠ Could not write PID file — exiting" -ForegroundColor Red
            exit 1
        }
        Write-WatchdogLog "PID_FILE_WRITTEN pid=$PID"
    } finally { $lockFile.Close() }
} catch {
    Write-WatchdogLog "PID_FILE_LOCK_FAILED error='$($_.Exception.Message)'" -Level WARN
    Write-Host "  ⚠ Could not acquire PID file lock — exiting" -ForegroundColor Red
    exit 1
}
Write-WatchdogLog "WATCHDOG_START pid=$PID watchInterval=${WatchIntervalSeconds}s maxWatchMinutes=$MaxWatchMinutes"

# ─── Preflight: verify orchestrator script compiles ───────────────
$orchScript = "$PSScriptRoot/LocalOrchestrator.ps1"
$orchErrors = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($orchScript, [ref]$null, [ref]$orchErrors)
if ($orchErrors) {
    $errorMsgs = ($orchErrors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
    Write-WatchdogLog "ORCHESTRATOR_PARSE_ERROR errors='$errorMsgs'" -Level ERROR
    Write-Host "  ⚠ Orchestrator script has parse errors — see watchdog log" -ForegroundColor Red
    "$errorMsgs" | Out-File (Join-Path $RepoDir "Tasks/Logs/.orchestrate-parse-error") -Encoding utf8
    exit 1
}
Write-WatchdogLog "ORCHESTRATOR_PARSE_OK script='$orchScript'"

# ─── Module preflight: verify the Interclaw.Orchestrate module loads correctly ──
$orchModulePath = Join-Path $PSScriptRoot "..\Modules\Interclaw.Orchestrate\Interclaw.Orchestrate.psd1"
if (-not (Test-Path $orchModulePath)) {
    Write-Host "  ⚠ Interclaw.Orchestrate module not found at $orchModulePath" -ForegroundColor Red
    exit 1
}
Write-WatchdogLog "MODULE_PREFLIGHT_OK module='$orchModulePath'"

# ─── Startup cleanup: remove stale agent PID files ────────────────
# Covers all agent types: coder, reviewer, stream, lane agents.
$stalePatterns = @('code-*', 'coder-*', 'reviewer-*', 'stream-*', 'lane-*')
foreach ($pidFile in Get-ChildItem "$AgentDir/*.pid" -ErrorAction SilentlyContinue) {
    $agentId = $pidFile.BaseName
    $isStalePattern = $false
    foreach ($p in $stalePatterns) {
        if ($agentId -like $p) { $isStalePattern = $true; break }
    }
    if (-not $isStalePattern) { continue }
    $procId = (Get-Content $pidFile.FullName -Raw -ErrorAction SilentlyContinue).Trim() -as [int]
    if (-not $procId) { continue }
    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) { continue }
    Remove-Item $pidFile.FullName -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $AgentDir "${agentId}.heartbeat") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $AgentDir "${agentId}.mode") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $AgentDir "${agentId}.stdout") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $AgentDir "${agentId}.stderr") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $AgentDir "${agentId}.log") -Force -ErrorAction SilentlyContinue
    Write-WatchdogLog "STARTUP_ZOMBIE_CLEAN agentId=$agentId procId=$procId" -Level INFO
}
Write-WatchdogLog "STARTUP_ZOMBIE_CLEAN_COMPLETE"

# ─── Crash evidence preservation ───────────────────────────────────
$CrashDir = Join-Path $LogDir "crashes"

function Save-CrashEvidence {
    param([string]$AgentId, [string]$Label)
    $existingEvidence = Get-ChildItem (Join-Path $CrashDir "${AgentId}-*") -Directory -ErrorAction SilentlyContinue
    if ($existingEvidence) {
        Write-WatchdogLog "CRASH_EVIDENCE_SKIP agentId=$AgentId label='$Label' existing='$($existingEvidence[0].Name)'" -Level WARN
        return
    }
    $evidenceDir = Join-Path $CrashDir "${AgentId}-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $null = New-Item -ItemType Directory -Path $evidenceDir -Force
    # Copy agent stdout, stderr, log, pid, heartbeat files if they exist
    foreach ($ext in @('stdout', 'stderr', 'log', 'pid', 'heartbeat', 'mode')) {
        $src = Join-Path $AgentDir "${AgentId}.${ext}"
        try {
            Copy-Item -LiteralPath $src -Destination (Join-Path $evidenceDir "${AgentId}.${ext}") -Force -ErrorAction Stop
        } catch [System.Management.Automation.ItemNotFoundException] {
            # Optional artifact absent — nothing to copy
        } catch {
            Write-WatchdogLog "EVIDENCE_COPY_FAILED agent='$AgentId' ext='$ext' error='$($_.Exception.Message)'" -Level WARN
        }
    }
    # Write a summary
    $summary = @{
        agent_id = $AgentId
        label    = $Label
        preserved_at = (Get-Date -Format 'o')
        src_dir  = $AgentDir
        evidence_dir = $evidenceDir
    } | ConvertTo-Json -Compress
    $summary | Out-File (Join-Path $evidenceDir "crash-summary.json") -Encoding utf8 -NoNewline

    # Write structured marker for RunFix consumption (via file for detach-mode polling)
    $marker = "CRASH_EVIDENCE: ${AgentId} -> ${evidenceDir}"
    Write-Host "  $marker" -ForegroundColor Red
    # Write to last-crash-evidence file so the detach-mode poll can report it to RunFix
    $lastCrashFile = Join-Path $LogDir ".last-crash-evidence"
    $existing = @()
    if (Test-Path $lastCrashFile) {
        try { $existing = Get-Content $lastCrashFile -Encoding utf8 -ErrorAction SilentlyContinue } catch { Write-WatchdogLog "LAST_CRASH_READ_FAILED error='$_'" -Level WARN }
    }
    [System.IO.File]::WriteAllLines($lastCrashFile, ($existing + $marker))
    Write-WatchdogLog "CRASH_EVIDENCE agentId=$AgentId label='$Label' evidenceDir='$evidenceDir'" -Level WARN
}

# ─── Local task/agent counters (avoids dependency on module's private functions) ──
function Get-TaskCounts {
    $rootCoder = @(Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $review = @(Get-ChildItem "$RepoDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $handoff = @(Get-ChildItem "$RepoDir/Tasks/Handoff/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $failed = @(Get-ChildItem "$RepoDir/Tasks/Failed/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $todo = @(Get-ChildItem "$RepoDir/Tasks/ToDo/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $manual = @(Get-ChildItem "$RepoDir/Tasks/Manual/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $paused = @(Get-ChildItem "$RepoDir/Tasks/Paused/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $completeFiles = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $completeDirs = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Directory -ErrorAction SilentlyContinue).Count
    $working = @(Get-ChildItem "$RepoDir/Tasks/Working" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    $lockedCoder = 0; $lockedReviewer = 0
    $coderAgents = @{}; $reviewerAgents = @{}
    $streamDirs = @(Get-ChildItem "$RepoDir/Tasks/Working/stream-*" -Directory -ErrorAction SilentlyContinue)
    $activeStreams = $streamDirs.Count
    foreach ($f in $working) {
        $agentId = $f.Directory.Name
        if ($agentId -match 'coder-(\d+-\d+)') { $lockedCoder++; $coderAgents[$Matches[1]] = $true }
        if ($agentId -match 'reviewer-(\d+-\d+)') { $lockedReviewer++; $reviewerAgents[$Matches[1]] = $true }
    }
    return [PSCustomObject]@{
        RootCoder = $rootCoder; Review = $review; Handoff = $handoff; Working = $working.Count; Failed = $failed
        ToDo = $todo; Manual = $manual; Paused = $paused; CompleteFiles = $completeFiles; CompleteDirs = $completeDirs
        LockedCoder = $lockedCoder; LockedReviewer = $lockedReviewer
        CoderWorkload = $rootCoder + $lockedCoder; ReviewerWorkload = $review + $lockedReviewer
        CoderAgents = $coderAgents; ReviewerAgents = $reviewerAgents; ActiveStreams = $activeStreams
    }
}
function Get-AgentFleetStatus {
    $results = [System.Collections.Generic.List[object]]::new()
    $logDir = "$RepoDir/Tasks/Logs"
    $agentDir = Join-Path $logDir "agents"
    foreach ($pidFile in Get-ChildItem "$agentDir/*.pid" -ErrorAction SilentlyContinue) {
        $agentId = $pidFile.BaseName
        if ([string]::IsNullOrWhiteSpace($agentId)) {
            Write-WatchdogLog "AGENT_SKIP_EMPTY_ID file='$($pidFile.Name)'" -Level WARN
            Remove-Item $pidFile.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        $rawContent = Get-Content $pidFile.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $rawContent) { continue }
        $procPid = 0; $pidStr = $rawContent.Trim()
        if (-not [int]::TryParse($pidStr, [ref]$procPid) -or $procPid -le 0) {
            Write-WatchdogLog "AGENT_SKIP_INVALID_PID agent=$agentId pid='$pidStr'" -Level WARN
            continue
        }
        $alive = Get-Process -Id $procPid -ErrorAction SilentlyContinue
        $role = if ($agentId -match '^coder-') { "coder" } elseif ($agentId -match '^reviewer-') { "reviewer" } elseif ($agentId -match '^watchdog-') { "watchdog" } else { "agent" }
        $modeFile = Join-Path $agentDir "$agentId.mode"
        $mode = if (Test-Path $modeFile) { (Get-Content $modeFile -Raw -ErrorAction SilentlyContinue).Trim() } else { "terminal" }
        $heartbeatFile = Join-Path $agentDir "$agentId.heartbeat"
        $elapsed = if ($alive -and (Test-Path $heartbeatFile)) {
            $hb = (Get-Content $heartbeatFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
            if ($hb) { [math]::Round(((Get-Date).ToUniversalTime() - $hb.ToUniversalTime()).TotalSeconds) } else { $null }
        }
        $logFile = Join-Path $agentDir "$agentId.log"
        $results.Add([PSCustomObject]@{ AgentId=$agentId; PID=$procPid; Role=$role; Mode=$mode; Status=if ($alive){"RUNNING"}else{"STALE"}; Elapsed=if ($elapsed){"$($elapsed)s"}else{"-"}; LogFile=$logFile })
    }
    return $results | Sort-Object Status, Role, AgentId
}
function Test-ProcessMatch {
    param([int]$ProcessId, [string]$ExpectedName)
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    return $proc.ProcessName -eq $ExpectedName
}

# ─── Spawned PID Registry (inline — module not loaded in watchdog process) ──
$script:SpawnedPidsRegistryPath = Join-Path $RepoDir "Tasks/Logs/agents/.spawned-pids.json"

function Initialize-SpawnedPidRegistry {
    $null = New-Item -ItemType Directory -Path (Split-Path $script:SpawnedPidsRegistryPath -Parent) -Force
    try {
        $null = Get-Item -LiteralPath $script:SpawnedPidsRegistryPath -ErrorAction Stop
    } catch {
        '{"pids":[],"byAgent":{}}' | Set-Content $script:SpawnedPidsRegistryPath -Encoding utf8 -NoNewline
    }
}

function Get-SpawnedPids {
    if (-not (Test-Path $script:SpawnedPidsRegistryPath)) { return @() }
    try {
        $data = Get-Content $script:SpawnedPidsRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) { return @() }
        return @($data.pids)
    } catch { return @() }
}

function Register-SpawnedPid {
    param([int]$ProcessId, [string]$AgentId = "")
    try {
        $data = Get-Content $script:SpawnedPidsRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) { $data = [PSCustomObject]@{ pids = @(); byAgent = @{} } }
        $priorPid = $null
        if ($AgentId -and $data.byAgent.PSObject.Properties.Name -contains $AgentId) {
            $priorPid = [int]$data.byAgent.$AgentId
        }
        if ($priorPid -and $priorPid -ne $ProcessId) {
            $data.pids = @($data.pids | Where-Object { [int]$_ -ne $priorPid })
        }
        if ($data.pids -notcontains $ProcessId) { $data.pids += $ProcessId }
        if ($AgentId) { $data.byAgent | Add-Member -NotePropertyName $AgentId -NotePropertyValue $ProcessId -Force }
        $data | ConvertTo-Json -Depth 3 | Set-Content $script:SpawnedPidsRegistryPath -Encoding utf8 -NoNewline
    } catch { Write-WatchdogLog "REGISTER_PID_FAILED pid=$ProcessId agentId=$AgentId error='$($_.Exception.Message)'" -Level WARN }
}

function Unregister-SpawnedPid {
    param([int]$ProcessId, [string]$AgentId = "")
    if (-not (Test-Path $script:SpawnedPidsRegistryPath)) { return }
    try {
        $data = Get-Content $script:SpawnedPidsRegistryPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $data) { return }
        $data.pids = @($data.pids | Where-Object { $_ -ne $ProcessId })
        if ($AgentId -and $data.byAgent.PSObject.Properties.Name -contains $AgentId -and [int]$data.byAgent.$AgentId -eq $ProcessId) {
            $data.byAgent.PSObject.Properties.Remove($AgentId)
        }
        $data | ConvertTo-Json -Depth 3 | Set-Content $script:SpawnedPidsRegistryPath -Encoding utf8 -NoNewline
    } catch { Write-WatchdogLog "UNREGISTER_PID_FAILED pid=$ProcessId agentId=$AgentId error='$($_.Exception.Message)'" -Level WARN }
}

function Test-IsSpawnedPid {
    param([int]$ProcessId)
    return (Get-SpawnedPids) -contains $ProcessId
}

function Stop-SpawnedProcess {
    param([int]$ProcessId, [switch]$Force)
    if (-not (Test-IsSpawnedPid -ProcessId $ProcessId)) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        $procName = if ($proc) { $proc.ProcessName } else { "unknown" }
        Write-WatchdogLog "STOP_SPAWNED_SKIP_UNREGISTERED pid=$ProcessId name=$procName — not in spawned PID registry" -Level WARN
        return $false
    }
    try {
        Stop-Process -Id $ProcessId -Force:$Force -ErrorAction Stop
        Write-WatchdogLog "STOP_SPAWNED_OK pid=$ProcessId"
        return $true
    } catch {
        Write-WatchdogLog "STOP_SPAWNED_FAILED pid=$ProcessId error='$($_.Exception.Message)'" -Level WARN
        return $false
    }
}

# ─── Initialize spawned-PID registry ────────────────────────────
Initialize-SpawnedPidRegistry
Write-WatchdogLog "SPAWNED_PID_REGISTRY_INIT path='$script:SpawnedPidsRegistryPath'"

function Stop-ProcessTree {
    param([int]$ProcessId, [switch]$Force)
    # Kill a process and all its descendants (children first, then parent)
    # Prevents orphaned opencode.exe children from leaking after orchestrator kill
    if (-not (Test-IsSpawnedPid -ProcessId $ProcessId)) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        $procName = if ($proc) { $proc.ProcessName } else { "unknown" }
        Write-WatchdogLog "STOP_TREE_SKIP_UNREGISTERED pid=$ProcessId name=$procName — not in spawned PID registry" -Level WARN
        return $false
    }
    $killedPids = @()
    try {
        # Recursively find all descendant PIDs via CIM
        $toKill = [System.Collections.Generic.Queue[int]]::new()
        $toKill.Enqueue($ProcessId)
        $allPids = [System.Collections.Generic.List[int]]::new()
        $allPids.Add($ProcessId)
        $visited = [System.Collections.Generic.HashSet[int]]::new()
        [void]$visited.Add($ProcessId)
        while ($toKill.Count -gt 0) {
            $currentPid = $toKill.Dequeue()
            try {
                $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$currentPid" -ErrorAction SilentlyContinue
                foreach ($child in $children) {
                    $childPid = [int]$child.ProcessId
                    if (-not $visited.Contains($childPid)) {
                        [void]$visited.Add($childPid)
                        [void]$allPids.Add($childPid)
                        $toKill.Enqueue($childPid)
                    }
                }
            } catch { Write-WatchdogLog "CIM_CHILD_QUERY_FAILED pid=$currentPid error='$($_.Exception.Message)'" -Level WARN }
        }
        # Kill children first (reverse order), then the root
        for ($idx = $allPids.Count - 1; $idx -ge 0; $idx--) {
            $pidToKill = $allPids[$idx]
            try {
                $proc = Get-Process -Id $pidToKill -ErrorAction SilentlyContinue
                if ($proc) {
                    Stop-Process -Id $pidToKill -Force:$Force -ErrorAction Stop
                    $killedPids += $pidToKill
                }
            } catch { Write-WatchdogLog "STOP_PROCESS_FAILED pid=$pidToKill error='$($_.Exception.Message)'" -Level WARN }
        }
        Write-WatchdogLog "STOP_TREE_OK root=$ProcessId killed=$($killedPids.Count) pids='$($killedPids -join ',')'"
        return $true
    } catch {
        Write-WatchdogLog "STOP_TREE_FAILED root=$ProcessId error='$($_.Exception.Message)' killed='$($killedPids -join ',')'" -Level WARN
        return $false
    }
}

function Invoke-SafeMove {
    param([string]$Source, [string]$Destination, [string]$Label = "", [int]$MaxRetries = 3)
    $backoff = @(1, 2, 3)
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        # Skip if file already disappeared (concurrent agent already moved it)
        if (-not (Test-Path -LiteralPath $Source)) {
            if ($Label) { Write-WatchdogLog "SAFE_MOVE_SKIP label='$Label' source='$Source' — file disappeared" -Level WARN }
            return $true
        }
        # Skip if destination already exists (concurrent agent already placed it)
        try {
            $null = Get-Item -LiteralPath $Destination -ErrorAction Stop
            $destExists = $true
        } catch {
            $destExists = $false
        }
        if ($destExists) {
            if ($Label) { Write-WatchdogLog "SAFE_MOVE_SKIP label='$Label' dest='$Destination' — destination already exists" -Level WARN }
            try { Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue } catch { Write-WatchdogLog "SAFE_MOVE_CLEANUP_FAILED label='$Label' error='$($_.Exception.Message)'" -Level WARN }
            return $true
        }
        try {
            $tempDest = "$Destination.tmp.$PID.$([IO.Path]::GetRandomFileName())"
            Move-Item -LiteralPath $Source -Destination $tempDest -Force -ErrorAction Stop
            Rename-Item -LiteralPath $tempDest -NewName ([IO.Path]::GetFileName($Destination)) -Force -ErrorAction Stop
            if ($Label) { Write-WatchdogLog "SAFE_MOVE_OK label='$Label' dest='$Destination'" }
            return $true
        } catch {
            # Clean up temp file if rename failed
            if (Test-Path -LiteralPath $tempDest) { Remove-Item -LiteralPath $tempDest -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt $MaxRetries) {
                $delay = if ($attempt -le $backoff.Count) { $backoff[$attempt - 1] } else { $backoff[-1] }
                if ($Label) { Write-WatchdogLog "SAFE_MOVE_RETRY label='$Label' attempt=$attempt delay=${delay}s error='$($_.Exception.Message)'" -Level WARN }
                Start-Sleep -Seconds $delay
            } else {
                if ($Label) { Write-WatchdogLog "SAFE_MOVE_FAILED label='$Label' error='$($_.Exception.Message)'" -Level ERROR }
                Write-Host "  ⚠ Failed to move ${Label}: $($_.Exception.Message)" -ForegroundColor Yellow
                return $false
            }
        }
    }
    return $false
}

function Write-FleetStatusTable {
    $fleet = Get-AgentFleetStatus
    if (-not $fleet) { return }
    $running = $fleet | Where-Object { $_.Status -eq "RUNNING" }
    if (-not $running) { return }
    Write-Host "  Active Agents:" -ForegroundColor Cyan
    foreach ($a in $running) {
        $roleIcon = switch ($a.Role) { "orchestrator" { "o" } "coder" { "c" } "reviewer" { "r" } default { "-" } }
        Write-Host "  $roleIcon $($a.AgentId) (PID $($a.PID)) - $($a.Role), $($a.Elapsed)" -ForegroundColor DarkGray
    }
}

# ─── Watchdog self-registration ───────────────────────────────────
$watchdogAgentId = "watchdog-$PID"
$watchdogPidFile = Join-Path $AgentDir "$watchdogAgentId.pid"
$watchdogHbFile = Join-Path $AgentDir "$watchdogAgentId.heartbeat"
$null = New-Item -ItemType Directory -Path $AgentDir -Force
$PID.ToString() | Out-File $watchdogPidFile -Encoding utf8 -NoNewline
[datetime]::UtcNow.ToString('o') | Out-File $watchdogHbFile -Encoding utf8 -NoNewline
Write-WatchdogLog "WATCHDOG_SELF_REGISTER agentId=$watchdogAgentId pid=$PID"

# ─── Launch orchestrator detached ─────────────────────────────────
$pwsh = Get-Command pwsh.exe | Select-Object -ExpandProperty Source

$extraArgs = ""
if ($Harness) { $extraArgs += " -Harness $Harness" }
if ($Provider) { $extraArgs += " -Provider $Provider" }
if ($Model) { $extraArgs += " -Model $Model" }
if ($Effort) { $extraArgs += " -Effort $Effort" }
if ($CodeParallelCount) { $extraArgs += " -CodeParallelCount $CodeParallelCount" }
if ($ReviewerParallelCount) { $extraArgs += " -ReviewerParallelCount $ReviewerParallelCount" }
if ($MaxRuntimeMinutes) { $extraArgs += " -MaxRuntimeMinutes $MaxRuntimeMinutes" }
if ($PollIntervalSeconds) { $extraArgs += " -PollIntervalSeconds $PollIntervalSeconds" }
if ($IdleTimeoutMinutes) { $extraArgs += " -IdleTimeoutMinutes $IdleTimeoutMinutes" }
$extraArgs += " -ModuleCount $ModuleCount"
$orchCmd = "& '$orchScript' -Detach -NoAuditPrompt -Executor $Executor$extraArgs"
$bytes = [System.Text.Encoding]::Unicode.GetBytes($orchCmd)
$encodedCmd = [Convert]::ToBase64String($bytes)
Write-WatchdogLog "LAUNCH cmd='$orchCmd'"

try { Clear-Host } catch { Write-WatchdogLog "CLEAR_HOST_FAILED error='$_'" -Level WARN }
Write-Host "╔══ Orchestrate ════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Launching local orchestrator in detached mode...             ║" -ForegroundColor DarkGray
Write-Host "╚═══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Resource guard — track spawned agent count
$script:spawnCount = 0
if ($script:spawnCount -ge $MaxAgentCount) {
    Write-Warning "Max agent count ($MaxAgentCount) exceeded — refusing to spawn"
    Write-WatchdogLog "RESOURCE_LIMIT spawnCount=$script:spawnCount max=$MaxAgentCount" -Level WARN
    exit 1
}
$proc = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-EncodedCommand', $encodedCmd) -WindowStyle Hidden -PassThru
Register-SpawnedPid -ProcessId $proc.Id -AgentId "orchestrator-wrapper-$PID"
$script:spawnCount++
Write-Host "  ✓ Orchestrator wrapper launched (PID $($proc.Id)) — spawn #$script:spawnCount" -ForegroundColor Green
Write-Host ""
Write-WatchdogLog "LAUNCHED wrapperPid=$($proc.Id)"

# ─── Wait for orchestrator PID to appear (with retry) ─────────────
$orchPid = $null
$waitCycles = 0
while ($waitCycles -lt 6) {
    Start-Sleep -Seconds 5
    $waitCycles++
    $pidFile = Get-OrchestratorPidFile
    if (-not $pidFile) { continue }
    $pidContent = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($pidContent -and ($pidContent -as [int])) {
        $orchPid = $pidContent -as [int]
        $PidLockFile = $pidFile
        break
    }
}
$script:lastOrchPid = $orchPid
if ($orchPid) {
    $orchProc = Get-Process -Id $orchPid -ErrorAction SilentlyContinue
    Write-WatchdogLog "ORCHESTRATOR_DETECTED pid=$orchPid alive=$($null -ne $orchProc)"
} else {
    Write-WatchdogLog "ORCHESTRATOR_NOT_DETECTED wrapperPid=$($proc.Id) - check LocalOrchestrator.ps1 for parse errors" -Level WARN
}

# ─── Watchdog loop ────────────────────────────────────────────────
$watchCycle = 0
$watchStart = Get-Date
$maxWatchCycles = if ($MaxWatchMinutes -gt 0) { [math]::Max(1, [math]::Ceiling($MaxWatchMinutes * 60 / $WatchIntervalSeconds)) } else { 0 }
$previousQueueCounts = $null
$recoveryCount = 0
$success = $false
$consecutiveNoProgress = 0
$maxConsecutiveNoProgress = 5
$script:lastOrchPid = $null
$auditLaunched = $false
$auditProcess = $null
$auditExited = $false
$skipSleepThisCycle = $false

while ($true) {
    $watchCycle++
    if ($maxWatchCycles -gt 0 -and $watchCycle -gt $maxWatchCycles) {
        Write-Host "  ⏱ Max watch time reached ($MaxWatchMinutes min) — exiting" -ForegroundColor Yellow
        break
    }

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()

    if ($skipSleepThisCycle) {
        $skipSleepThisCycle = $false
    } else {
        Start-Sleep -Seconds $WatchIntervalSeconds
    }

    # ── Gather state ──────────────────────────────────────────────
    try {
        $counts = Get-TaskCounts
    } catch {
        Write-WatchdogLog "GET_TASK_COUNTS_FAILED error='$_' — using fallback" -Level WARN
        $counts = [PSCustomObject]@{
            RootCoder = @(Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            Review = @(Get-ChildItem "$RepoDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            Working = @(Get-ChildItem "$RepoDir/Tasks/Working" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            Failed = @(Get-ChildItem "$RepoDir/Tasks/Failed/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            ToDo = @(Get-ChildItem "$RepoDir/Tasks/ToDo/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            Manual = @(Get-ChildItem "$RepoDir/Tasks/Manual/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            Paused = @(Get-ChildItem "$RepoDir/Tasks/Paused/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            CompleteFiles = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            CompleteDirs = @(Get-ChildItem "$RepoDir/Tasks/Complete" -Directory -ErrorAction SilentlyContinue).Count
            LockedCoder = 0; LockedReviewer = 0
            CoderWorkload = 0; ReviewerWorkload = 0; ActiveStreams = 0
        }
        $counts.CoderWorkload = $counts.RootCoder + $counts.LockedCoder
        $counts.ReviewerWorkload = $counts.Review + $counts.LockedReviewer
    }
    try {
        $fleet = Get-AgentFleetStatus
    } catch {
        Write-WatchdogLog "GET_AGENT_FLEET_STATUS_FAILED error='$_' — using empty fallback" -Level WARN
        $fleet = @()
    }

    # ── Fleet container health probe (defence-in-depth alongside is-fleet) ──
    # The watchdog runs on the host with docker CLI access. If is-tempo or
    # is-fleet is down, the watchdog can restart it — this is a redundant
    # second self-healer that catches cases where is-fleet itself is dead.
    try {
        $tempoHealthy = $false
        try {
            $tempoResp = Invoke-RestMethod -Uri "http://127.0.0.1:29996/api/health" -TimeoutSec 5 -ErrorAction Stop
            $tempoHealthy = $true
        } catch {
            $tempoHealthy = $false
        }
        if (-not $tempoHealthy) {
            Write-WatchdogLog "FLEET_CONTAINER_UNHEALTHY service=is-tempo — attempting restart" -Level WARN
            $stackName = (docker stack ls --format "{{.Name}}" 2>$null | Select-Object -First 1)
            if ($stackName) {
                $svc = "${stackName}_is-tempo"
                docker service update --force $svc 2>&1 | Out-Null
                Write-WatchdogLog "FLEET_CONTAINER_RESTART service=is-tempo action=docker service update --force $svc" -Level WARN
            }
        }
    } catch {
        Write-WatchdogLog "FLEET_CONTAINER_PROBE_ERROR error='$_'" -Level WARN
    }

    # Re-detect orchestrator PID on each cycle using dynamic glob scan
    if (-not $orchPid -or -not (Get-Process -Id $orchPid -ErrorAction SilentlyContinue)) {
        $pidFile = Get-OrchestratorPidFile
        if ($pidFile) {
            $PidLockFile = $pidFile
            $pidContent = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($pidContent) { $orchPid = $pidContent -as [int] }
        }
    }
    $orchAlive = $orchPid -and (Get-Process -Id $orchPid -ErrorAction SilentlyContinue)
    $progressHealth = Get-OrchestratorProgressHealth `
        -CompleteDir "$RepoDir/Tasks/Complete" `
        -CodeCount $counts.RootCoder -ReviewCount $counts.Review -HandoffCount $counts.Handoff `
        -WorkingCount $counts.Working -FailedCount $counts.Failed `
        -OrchestratorAlive ([bool]$orchAlive) -ActiveStreams $counts.ActiveStreams
    if ($progressHealth.Stalled) {
        Write-WatchdogLog "ORCHESTRATOR_PROGRESS_STALLED reason=$($progressHealth.Reason) completionAgeMinutes=$($progressHealth.CompletionAgeMinutes) code=$($counts.RootCoder) review=$($counts.Review) handoff=$($counts.Handoff) working=$($counts.Working)" -Level WARN
    }
    # Queue progress is a separate semantic escalation check. A live process
    # with zero streams and repeated dispatch failures is not healthy. Invoke
    # Fix Orchestrator once per escalation window; it stops the child before
    # probing and diagnosis, then the normal recovery path can relaunch it.
    $queueHealth = $null
    try {
        $queueHealthScript = Join-Path $PSScriptRoot 'Get-QueueProgressHealth.ps1'
        if (Test-Path -LiteralPath $queueHealthScript) {
            $queueHealth = (& $queueHealthScript -Root $RepoDir | ConvertFrom-Json)
            if ($queueHealth.FixDue) {
                Write-WatchdogLog "FIX_ORCHESTRATOR_TRIGGER reason=$($queueHealth.Reason) stagnantMinutes=$($queueHealth.StagnantMinutes) sameFingerprintChecks=$($queueHealth.SameFingerprintCount) dispatchBlocked=$($queueHealth.DispatchBlockedCount) activeStreams=$($queueHealth.ActiveStreams)" -Level WARN
                $fixScript = Join-Path $PSScriptRoot 'Invoke-FixOrchestrator.ps1'
                if (Test-Path -LiteralPath $fixScript) {
                    $fixResult = & $fixScript -RepoRoot $RepoDir -Force -Reason ([string]$queueHealth.Reason)
                    Write-WatchdogLog "FIX_ORCHESTRATOR_RESULT result=$([string]$fixResult)" -Level WARN
                }
            }
        }
    } catch {
        Write-WatchdogLog "FIX_ORCHESTRATOR_CHECK_FAILED error='$_'" -Level WARN
    }
    # Reset reload count on successful orchestrator detection
    if ($orchAlive) {
        $script:lastOrchPid = $orchPid
        Get-ChildItem "$RepoDir/Tasks/Logs/.orchestrate-reload-count-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $allEmpty = ($counts.CoderWorkload -eq 0) -and ($counts.ReviewerWorkload -eq 0) -and ($counts.Working -eq 0)

    # ── Display status ────────────────────────────────────────────
    $elapsedMin = [math]::Floor(((Get-Date) - $watchStart).TotalMinutes)
    $elapsedSec = [math]::Round(((Get-Date) - $watchStart).TotalSeconds - ($elapsedMin * 60))

    try { Clear-Host } catch { Write-WatchdogLog "CLEAR_HOST_CYCLE_FAILED error='$_'" -Level WARN }
    Write-Host "╔══ Orchestrate Watchdog — Cycle $watchCycle ═══════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  Elapsed: ${elapsedMin}m${elapsedSec}s                                ║" -ForegroundColor DarkGray
    Write-Host "║  Orchestrator: $(if($orchAlive){'RUNNING '}else{'STOPPED'})  Queues: Code=$($counts.CoderWorkload)  Review=$($counts.ReviewerWorkload)  Handoff=$($counts.Handoff)  Working=$($counts.Working)  ║" -ForegroundColor $(if($allEmpty){'Green'}else{'Yellow'})
    Write-Host "║  Other: Failed=$($counts.Failed)  ToDo=$($counts.ToDo)  Manual=$($counts.Manual)  Paused=$($counts.Paused)  Complete=$($counts.CompleteFiles)+$($counts.CompleteDirs)  ║" -ForegroundColor DarkGray
    Write-Host "║  Re-launches: $recoveryCount                                            ║" -ForegroundColor DarkGray
    Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    # Inline fleet status table (avoid missing functions from unloaded module)
    try { Write-FleetStatusTable } catch {
        $agentFiles = Get-ChildItem "$AgentDir/*.pid" -ErrorAction SilentlyContinue | Select-Object -First 10
        if ($agentFiles) {
            Write-Host "  Agents: $($agentFiles.Count) registered" -ForegroundColor DarkGray
            foreach ($af in $agentFiles) {
                $pidContent = Get-Content $af.FullName -Raw -ErrorAction SilentlyContinue
                $pidVal = if ($pidContent) { $pidContent.Trim() -as [int] } else { $null }
                $alive = $pidVal -and (Get-Process -Id $pidVal -ErrorAction SilentlyContinue)
                Write-Host "    $($af.BaseName): PID=$pidVal Alive=$alive" -ForegroundColor DarkGray
            }
        }
    }

    # ── Cycle summary ──────────────────────────────────────────────
    Write-WatchdogLog "CYCLE cycle=$watchCycle elapsed=${elapsedMin}m${elapsedSec}s orchAlive=$orchAlive code=$($counts.CoderWorkload) review=$($counts.ReviewerWorkload) handoff=$($counts.Handoff) working=$($counts.Working) recoveryCount=$recoveryCount"

    # ── Commit queue state periodically ───────────────────────────
    if ($watchCycle % 5 -eq 0) {
        try {
            Push-Location $RepoDir
            $status = (git status --porcelain 'Tasks/Code' 'Tasks/Working' 'Tasks/Complete' 'Tasks/Review' 'Tasks/Handoff' 'Tasks/Manual' 'Tasks/ToDo' 'Tasks/Paused' 'Tasks/Failed')
            if ($status) {
                git add -- 'Tasks/Code' 'Tasks/Working' 'Tasks/Complete' 'Tasks/Review' 'Tasks/Handoff' 'Tasks/Manual' 'Tasks/ToDo' 'Tasks/Paused' 'Tasks/Failed'
                if ((git diff --cached --quiet) -ne 0) {
                    $stagedFiles = (git diff --cached --name-only)
                    $isStreamMove = $stagedFiles | Where-Object { $_ -like 'Tasks/Working/*' -or $_ -like 'Tasks/Complete/*' }
                    $msgPrefix = if ($isStreamMove) { 'stream' } else { 'chore' }
                    git commit -m "$msgPrefix`: orchestrator queue state (cycle $watchCycle)" --quiet
                    git push --quiet
                }
            }
            Pop-Location
        } catch {
            Write-WatchdogLog "QUEUE_STATE_COMMIT_FAILED error='$_'" -Level WARN
        }
    }

    # ── Audit process heartbeat (when FinishWithAudit is on) ───────
    if ($FinishWithAudit -and $auditProcess) {
        if ($auditProcess.HasExited -and -not $auditExited) {
            $auditExited = $true
            $auditCodeCount = @(Get-ChildItem "$RepoDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
            Write-WatchdogLog "AUDIT_EXITED pid=$($auditProcess.Id) exitCode=$($auditProcess.ExitCode) codeCount=$auditCodeCount"
            Write-Host "  Audit process exited (code $($auditProcess.ExitCode)) — $auditCodeCount plan(s) in Tasks/Code/" -ForegroundColor Cyan
            # Ensure a fresh orchestrator can be launched for any generated plans
            Get-ChildItem "$LogDir\.orchestrator-*-pid" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
            if (Test-Path $HbFile) { Remove-Item $HbFile -Force -ErrorAction SilentlyContinue }
        } elseif (-not $auditProcess.HasExited) {
            Write-WatchdogLog "AUDIT_RUNNING pid=$($auditProcess.Id)"
        }
    }

    # Refresh watchdog heartbeat
    [datetime]::UtcNow.ToString('o') | Out-File $watchdogHbFile -Encoding utf8 -NoNewline

    # ── SUCCESS: orchestrator exited AND all queues empty ─────────
    if ($allEmpty -and -not $orchAlive) {
        if ($FinishWithAudit -and -not $auditLaunched) {
            $auditProcess = Start-CompleteAudit -RepoDir $RepoDir -LogDir $LogDir
            if ($auditProcess) {
                $auditLaunched = $true
                Write-WatchdogLog "AUDIT_TRIGGERED pid=$($auditProcess.Id)"
                Write-Host "  Audit launched (PID $($auditProcess.Id)) — waiting for plans..." -ForegroundColor Cyan
                $previousQueueCounts = $null
                $consecutiveNoProgress = 0
                continue
            } else {
                Write-Host "  ⚠ FinishWithAudit requested but audit could not be launched — exiting" -ForegroundColor Red
            }
        }
        if ($FinishWithAudit -and $auditLaunched -and -not $auditExited) {
            # Audit is still running; it may still produce more work
            continue
        }

        # Post Work Complete interactive checklist when Manual or Failed remain
        $manualRemaining = [int]$counts.Manual
        $failedRemaining = [int]$counts.Failed
        if ($manualRemaining -gt 0 -or $failedRemaining -gt 0) {
            Write-WatchdogLog "POST_WORK_CHECKLIST_START manual=$manualRemaining failed=$failedRemaining"
            $checklistResult = Show-PostWorkCompleteChecklist -RepoDir $RepoDir
            if (-not $checklistResult) {
                # User made a routing choice or new work appeared — resume immediately
                $skipSleepThisCycle = $true
                $previousQueueCounts = $null
                $consecutiveNoProgress = 0
                continue
            }
            # If checklist returned $true, no more Manual/Failed items or user chose to exit
        }

        $success = $true
        Write-WatchdogLog "SUCCESS cycles=$watchCycle elapsed=${elapsedMin}m${elapsedSec}s re-launches=$recoveryCount"
        try { Clear-Host } catch { Write-WatchdogLog "CLEAR_HOST_SUCCESS_FAILED error='$_'" -Level WARN }
        Write-Host "╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
        Write-Host "║                   ORCHESTRATE COMPLETE                            ║" -ForegroundColor Green
        Write-Host "╠════════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
        Write-Host "║  All queues successfully drained.                                 ║" -ForegroundColor Green
        Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
        Write-Host ""
        Write-Host "Summary:" -ForegroundColor Cyan
        Write-Host "  Total time:      ${elapsedMin}m${elapsedSec}s" -ForegroundColor DarkGray
        Write-Host "  Status:          All queues empty" -ForegroundColor Green
        Write-Host "  Re-launches:     $recoveryCount" -ForegroundColor DarkGray
        Write-Host "  End state:" -ForegroundColor DarkGray
        Write-Host "    Tasks/Code/:     $($counts.CoderWorkload) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Review/:   $($counts.ReviewerWorkload) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Handoff/:  $($counts.Handoff) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Working/:  $($counts.Working) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Failed/:   $($counts.Failed) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/ToDo/:     $($counts.ToDo) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Manual/:   $($counts.Manual) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Paused/:   $($counts.Paused) files" -ForegroundColor DarkGray
        Write-Host "    Tasks/Complete/: $($counts.CompleteFiles) files + $($counts.CompleteDirs) dirs" -ForegroundColor DarkGray
        break
    }

    # ── Mutex conflict detection ─────────────────────────────────
    # Detect when a stale orchestrator holds the mutex, preventing the new one from starting.
    # This is NOT a crash — the new orchestrator couldn't start because the old one is still alive.
    if (-not $orchAlive -and -not $allEmpty) {
        $orchActivePathMutex = Join-Path $RepoDir "Tasks/Logs/.orchestrator-active"
        if (Test-Path $orchActivePathMutex) {
            $ocContent = Get-Content $orchActivePathMutex -Raw -ErrorAction SilentlyContinue
            if ($ocContent) {
                $ocLines = $ocContent.Trim() -split "`n"
                $stalePid = if ($ocLines.Count -ge 1) { $ocLines[0].Trim() -as [int] } else { $null }
                if ($stalePid -and (Get-Process -Id $stalePid -ErrorAction SilentlyContinue) -and $stalePid -ne $script:lastOrchPid) {
                    Write-Host "  ⚔ Mutex conflict — stale orchestrator PID $stalePid holds the lock" -ForegroundColor Yellow
                    Write-WatchdogLog "MUTEX_CONFLICT stalePid=$stalePid lastOrchPid=$($script:lastOrchPid)" -Level WARN
                    # Only kill if registered in the spawned-PID registry (prevents killing interactive sessions)
                    Stop-ProcessTree -ProcessId $stalePid -Force
                    # Clean orchestrator artifacts
                    Get-ChildItem "$LogDir\.orchestrator-*-pid" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
                    $staleHb = Join-Path $LogDir ".orchestrator-heartbeat"
                    Remove-Item $staleHb -Force -ErrorAction SilentlyContinue
                    Remove-Item $orchActivePathMutex -Force -ErrorAction SilentlyContinue
                    # Do NOT increment recoveryCount or reloadCount — this was not a crash
                    Write-Host "  → Stale orchestrator killed — re-launching immediately" -ForegroundColor Yellow
                    # Re-launch
                    if ($script:spawnCount -lt $MaxAgentCount) {
                        $procMutex = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-EncodedCommand', $encodedCmd) -WindowStyle Hidden -PassThru
                        Register-SpawnedPid -ProcessId $procMutex.Id -AgentId "orchestrator-mutex-$PID"
                        $script:spawnCount++
                        Write-Host "  ✓ Orchestrator re-launched (PID $($procMutex.Id)) — spawn #$script:spawnCount" -ForegroundColor Green
                        $script:lastOrchPid = $procMutex.Id
                        $waitCyclesMutex = 0
                        while ($waitCyclesMutex -lt 6) {
                            Start-Sleep -Seconds 5
                            $waitCyclesMutex++
                            $pidFileMutex = Get-OrchestratorPidFile
                            if ($pidFileMutex) {
                                $PidLockFile = $pidFileMutex
                                $pidContent = (Get-Content $pidFileMutex -Raw -ErrorAction SilentlyContinue).Trim()
                                if ($pidContent -and ($pidContent -as [int])) {
                                    $orchPid = $pidContent -as [int]
                                    break
                                }
                            }
                        }
                    }
                    continue
                }
            }
        }
    }

    # ── Orchestrator stopped with work remaining ───────────────────
    if (-not $orchAlive -and -not $allEmpty) {
        $continueFile = Join-Path $RepoDir "Tasks/Logs/.orchestrator-continue"
        try { $null = Get-Item -LiteralPath $continueFile -ErrorAction Stop; $isContinue = $true } catch { $isContinue = $false }
        $isPostAuditRelaunch = $FinishWithAudit -and $auditLaunched -and -not $auditExited
        if ($isContinue) {
            Remove-Item $continueFile -Force -ErrorAction SilentlyContinue
            Write-WatchdogLog "ORCHESTRATOR_CONTINUE recoveryCount=$recoveryCount" -Level INFO
        } elseif ($isPostAuditRelaunch) {
            Write-WatchdogLog "ORCHESTRATOR_RELAUNCH_POST_AUDIT code=$($counts.CoderWorkload) review=$($counts.ReviewerWorkload) working=$($counts.Working)" -Level INFO
        } else {
            $recoveryCount++
            Write-WatchdogLog "ORCHESTRATOR_CRASH recoveryCount=$recoveryCount code=$($counts.CoderWorkload) review=$($counts.ReviewerWorkload) working=$($counts.Working)" -Level WARN
        }

        # Report init error if one was left by the failed orchestrator
        $initErrPath = Join-Path $RepoDir "Tasks/Logs/.orchestrator-init-error"
        try {
            $initErrItem = Get-Item -LiteralPath $initErrPath -ErrorAction Stop
        } catch [System.Management.Automation.ItemNotFoundException] {
            $initErrItem = $null
        }
        if ($initErrItem) {
            $initErr = Get-Content $initErrPath -Raw -ErrorAction SilentlyContinue
            Write-WatchdogLog "ORCHESTRATOR_INIT_ERROR reason='$initErr'" -Level ERROR
            Remove-Item $initErrItem.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "  ⚠ Orchestrator init error: $initErr" -ForegroundColor Red
        }

        if ($isPostAuditRelaunch) {
            Write-Host "  Relaunching orchestrator for audit-generated work..." -ForegroundColor Cyan
        } else {
            # Re-launch budget: max 5 attempts (per-instance counter)
            $reloadCountPath = Join-Path $RepoDir "Tasks/Logs/.orchestrate-reload-count-$PID"
            $reloadCount = try { [int](Get-Content $reloadCountPath -Raw -ErrorAction Stop).Trim() } catch { 0 }
            $reloadCount++
            $reloadCount | Out-File -FilePath $reloadCountPath -Encoding utf8 -NoNewline

            if ($reloadCount -ge 10) {
                Write-Host "  ⚠ Orchestrator crashed $reloadCount times — writing stop signal and exiting" -ForegroundColor Red
                Set-Content -Path (Join-Path $RepoDir "Tasks/stop") -Value "stop" -Encoding utf8 -NoNewline
                $report = "Orchestrator crashed $reloadCount times. Last crash: $(Get-Date -Format 'o').`nCheck Tasks/Logs/orchestrator-*.log for details."
                Set-Content -Path (Join-Path $RepoDir "Tasks/Logs/.orchestrate-crash-report") -Value $report -Encoding utf8 -NoNewline
                exit 1
            }
            Write-WatchdogLog "RELAUNCH_BUDGET attempt=$reloadCount max=5"

            $backoffDelay = [math]::Min([math]::Pow(2, $reloadCount - 1), 30)
            if ($backoffDelay -ge 1) {
                Write-WatchdogLog "CRASH_BACKOFF delay=${backoffDelay}s attempt=$reloadCount"
                Start-Sleep -Seconds $backoffDelay
            }

            Write-Host "  Recovery attempt #$recoveryCount" -ForegroundColor Yellow
        }

        if (-not $isContinue) {
        # Move orphaned files from Working/ back to source queues with retry-budget gating
        # (does NOT depend on orchestrator-internal scope like Rescue-OrphanedLocks)
        $retryBudgetPath = Join-Path $LogDir "file-retry-budget.json"
        $maxRetries = 3
        $orphanFiles = Get-ChildItem "$WorkingDir/*/*.md" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.gitkeep' }
        if ($orphanFiles) { Write-WatchdogLog "ORPHAN_RESCUE count=$($orphanFiles.Count) files='$(($orphanFiles | ForEach-Object { $_.Name }) -join ',')'" -Level WARN }
        $retryBudget = [PSCustomObject]@{}
        if (Test-Path $retryBudgetPath) {
            try { $retryBudget = Get-Content $retryBudgetPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { Write-WatchdogLog "RETRY_BUDGET_READ_FAILED error='$_'" -Level WARN }
        }
        if (-not $retryBudget) { $retryBudget = [PSCustomObject]@{} }
        foreach ($f in $orphanFiles) {
            $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            $role = if ($content -match '(?m)^-\s*Role:\s*(\S+)') { $Matches[1] } else { "coder" }
            $fileName = $f.Name
            $retryCount = if ($retryBudget.PSObject.Properties.Name -contains $fileName) { $retryBudget.$fileName.retries -as [int] } else { 0 }

            if ($retryCount -ge $maxRetries) {
                $failedDir = Join-Path $RepoDir "Tasks/Failed"
                $null = New-Item -ItemType Directory -Path $failedDir -Force
                $moved = Invoke-SafeMove -Source $f.FullName -Destination (Join-Path $failedDir $fileName) -Label "quarantine-$fileName"
                if ($moved) {
                    Write-Host "  ⚠ $fileName exceeded retry budget ($retryCount/$maxRetries) — quarantining" -ForegroundColor Yellow
                    Write-WatchdogLog "FILE_QUARANTINED file=$fileName retries=$retryCount max=$maxRetries" -Level WARN
                    if ($retryBudget.PSObject.Properties.Name -contains $fileName) {
                        $retryBudget.PSObject.Properties.Remove($fileName)
                    }
                }
                continue
            }

            if ($retryBudget.PSObject.Properties.Name -contains $fileName) {
                $retryBudget.$fileName.retries++
                $retryBudget.$fileName.lastAttempt = (Get-Date -Format 'o')
            } else {
                $retryBudget | Add-Member -NotePropertyName $fileName -NotePropertyValue @{
                    retries = 1; firstSeen = (Get-Date -Format 'o'); lastAttempt = (Get-Date -Format 'o')
                }
            }
            $destBase = if ($role -eq "reviewer") { "Review" } else { "Code" }
            $destDir = "$RepoDir/Tasks/$destBase"
            $null = New-Item -ItemType Directory -Path $destDir -Force
            $moved = Invoke-SafeMove -Source $f.FullName -Destination (Join-Path $destDir $f.Name) -Label "rescue-$fileName"
            if ($moved) {
                Write-Host "  ↪ $fileName → Tasks/$destBase/ (retry $($retryBudget.$fileName.retries))" -ForegroundColor DarkGray
            }
        }
        $null = New-Item -ItemType Directory -Path (Split-Path $retryBudgetPath -Parent) -Force
        try { $retryBudget | ConvertTo-Json -Depth 5 | Set-Content $retryBudgetPath -Encoding utf8 -NoNewline } catch { Write-WatchdogLog "RETRY_BUDGET_WRITE_FAILED error='$_'" -Level WARN }

        # Remove empty subdirs from Working/
        Get-ChildItem "$WorkingDir/*" -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

        # ── Clean leftover worktrees from prior crash ────────────────────
        . (Join-Path $skillsRoot "Git/Invoke-WorktreeSetup.ps1")
        . (Join-Path $skillsRoot "Git/Invoke-WorktreeCleanup.ps1")
        $existing = Get-ExistingWorktrees
        $orphanWorktrees = $existing | Where-Object {
            $agentPidFile = Join-Path $AgentDir "$($_.BranchName.Replace('wt/','')).pid"
            $pidContent = if (Test-Path $agentPidFile) { Get-Content $agentPidFile -Raw -ErrorAction SilentlyContinue } else { $null }
            $pidValue = if ($pidContent) { $pidContent.Trim() -as [int] } else { $null }
            # Module worktrees are persistent infrastructure shared by their
            # four lanes. They intentionally have no single module-level PID;
            # removing them here turns a valid registered worktree into a
            # plain directory and breaks module resume on the next iteration.
            $isPersistentModule = $_.BranchName -match '^wt/module-\d+$'
            $_.BranchName -match '^wt/' -and
            -not $isPersistentModule -and
            (-not $pidValue -or -not (Get-Process -Id $pidValue -ErrorAction SilentlyContinue))
        }
        foreach ($wt in $orphanWorktrees) {
            Write-Host "  Cleaning orphan worktree: $($wt.WorktreePath)" -ForegroundColor Yellow
            Remove-AgentWorktree -WorktreePath $wt.WorktreePath -BranchName $wt.BranchName
        }
        } # end skip-rescue for continue mode

        # Kill stale subagents (only kill PIDs we spawned — never kill opencode processes)
        $staleAgents = $fleet | Where-Object { $_.Status -eq "STALE" -and $_.Role -ne "orchestrator" }
        if ($staleAgents) {
            Write-WatchdogLog "STALE_AGENTS_RESCUE count=$($staleAgents.Count) agents='$(($staleAgents | ForEach-Object { $_.AgentId }) -join ',')'" -Level WARN
            foreach ($agent in $staleAgents) {
                $agentPid = [int]$agent.PID
                # SAFETY: verify process name before killing — prevents killing recycled PIDs
                if (-not (Test-ProcessMatch -ProcessId $agentPid -ExpectedName "pwsh")) {
                    if (Test-ProcessMatch -ProcessId $agentPid -ExpectedName "opencode") {
                        Write-WatchdogLog "AGENT_SKIP_OPENCODE agent=$($agent.AgentId) pid=$agentPid — skipping (may be user session)" -Level WARN
                    } else {
                        Write-WatchdogLog "AGENT_SKIP_PID_MISMATCH agent=$($agent.AgentId) pid=$agentPid — process name does not match 'pwsh' or 'opencode'" -Level WARN
                    }
                    continue
                }
                $completedNormallyCrash = $false
                if ($agent.AgentId -match '^stream-\d+$') {
                    $streamDirCrash = Join-Path $WorkingDir $agent.AgentId
                    if ((Test-Path (Join-Path $streamDirCrash ".complete"))) {
                        $completedNormallyCrash = $true
                        Write-WatchdogLog "STALE_AGENT_COMPLETED_CRASH agentId=$($agent.AgentId) — .complete found, skipping crash evidence" -Level INFO
                    }
                }
                if (-not $completedNormallyCrash) {
                    $hasAgentOutput = (Test-Path (Join-Path $AgentDir "$($agent.AgentId).stdout")) -or
                        (Test-Path (Join-Path $AgentDir "$($agent.AgentId).stderr")) -or
                        (Test-Path (Join-Path $AgentDir "$($agent.AgentId).log"))
                    if ($hasAgentOutput) {
                        Save-CrashEvidence -AgentId $agent.AgentId -Label "crash-recovery"
                    } else {
                        Write-WatchdogLog "STALE_AGENT_ZOMBIE agentId=$($agent.AgentId) — cleaned without crash evidence (no output files)" -Level INFO
                    }
                }
                Write-Host "  Cleaning stale agent: $($agent.AgentId)" -ForegroundColor Yellow
                Stop-SpawnedProcess -ProcessId $agentPid -Force
                Remove-Item (Join-Path $AgentDir "$($agent.AgentId).pid") -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $AgentDir "$($agent.AgentId).heartbeat") -Force -ErrorAction SilentlyContinue
            }
        }

        # Check stop signals before re-launching
        $stopPaths = @(
            (Join-Path $RepoDir "Tasks/stop"),
            (Join-Path $RepoDir "Tasks/stop.code"),
            (Join-Path $RepoDir "Tasks/stop.review")
        )
        if ($stopPaths | Where-Object { Test-Path $_ } | Select-Object -First 1) {
            Write-WatchdogLog "RELAUNCH_ABORTED reason=stop-signal recoveryCount=$recoveryCount" -Level WARN
            Write-Host "  ⏹ Stop signal detected — not re-launching" -ForegroundColor Yellow
            exit 1
        }

        # Clear orchestrator lock artifacts so new instance can start
        Get-ChildItem "$LogDir\.orchestrator-*-pid" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        if (Test-Path $HbFile) { Remove-Item $HbFile -Force -ErrorAction SilentlyContinue }

        # Resource guard
        if ($script:spawnCount -ge $MaxAgentCount) {
            Write-Warning "Max agent count ($MaxAgentCount) exceeded — re-launch refused"
            Write-WatchdogLog "RESOURCE_LIMIT spawnCount=$script:spawnCount max=$MaxAgentCount" -Level WARN
            continue
        }

        # Re-launch orchestrator (with -Continue if max-iterations handoff)
        $relaunchCmd = $orchCmd
        if ($isContinue) { $relaunchCmd += " -Continue" }
        $relaunchBytes = [System.Text.Encoding]::Unicode.GetBytes($relaunchCmd)
        $relaunchEncoded = [Convert]::ToBase64String($relaunchBytes)
        $proc2 = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NoLogo', '-EncodedCommand', $relaunchEncoded) -WindowStyle Hidden -PassThru
        Register-SpawnedPid -ProcessId $proc2.Id -AgentId "orchestrator-crash-recovery-$PID"
        $script:spawnCount++
        Write-Host "  ✓ Orchestrator re-launched (PID $($proc2.Id)) — spawn #$script:spawnCount" -ForegroundColor Green

        # Wait for PID file with retry (new orchestrator may take time to write it)
        $orchPid = $null
        $waitCycles = 0
        while ($waitCycles -lt 6) {
            Start-Sleep -Seconds 5
            $waitCycles++
            $pidFile = Get-OrchestratorPidFile
            if (-not $pidFile) { continue }
            $pidContent = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($pidContent -and ($pidContent -as [int])) {
                $orchPid = $pidContent -as [int]
                $script:lastOrchPid = $orchPid
                $PidLockFile = $pidFile
                break
            }
        }
        continue
    }

    # ── Stale subagents during normal running ─────────────────────
    $staleAgents = $fleet | Where-Object { $_.Status -eq "STALE" -and $_.Role -ne "orchestrator" }
    if ($staleAgents) {
        $staleHeartbeatSeconds = 300
        Write-WatchdogLog "STALE_AGENTS count=$($staleAgents.Count) agents='$(($staleAgents | ForEach-Object { $_.AgentId }) -join ',')'" -Level WARN
        foreach ($agent in $staleAgents) {
            $hbFile = Join-Path $AgentDir "$($agent.AgentId).heartbeat"
            $hbAge = $null
            if (Test-Path $hbFile) {
                $hbContent = (Get-Content $hbFile -Raw -ErrorAction SilentlyContinue).Trim()
                if ($hbContent) {
                    $hbDate = $hbContent -as [datetime]
                    if ($hbDate) { $hbAge = [math]::Round(((Get-Date).ToUniversalTime() - $hbDate.ToUniversalTime()).TotalSeconds) }
                }
            }
            if ($hbAge -is [double] -and $hbAge -gt $staleHeartbeatSeconds) {
                Write-WatchdogLog "STALE_AGENT_ORPHAN agentId=$($agent.AgentId) heartbeatAge=${hbAge}s threshold=${staleHeartbeatSeconds}s — cleaning without crash evidence" -Level INFO
            } else {
                # Check if this agent exited normally (not crashed)
                $completedNormally = $false
                if ($agent.AgentId -match '^stream-\d+$') {
                    $streamDir = Join-Path $WorkingDir $agent.AgentId
                    if (-not (Test-Path $streamDir)) {
                        # Orchestrator Phase B already cleaned up stream dir — agent completed normally
                        $completedNormally = $true
                        Write-WatchdogLog "STALE_AGENT_STREAM_CLEANED agentId=$($agent.AgentId) — stream dir gone, normal exit" -Level INFO
                    } elseif (Test-Path (Join-Path $streamDir ".complete")) {
                        $completedNormally = $true
                        Write-WatchdogLog "STALE_AGENT_COMPLETED agentId=$($agent.AgentId) — .complete found, normal exit" -Level INFO
                    }
                } elseif ($orchAlive) {
                    # Non-stream agents during normal running are orchestrator
                    # subprocesses that exit when their opencode agent finishes.
                    # Skip crash evidence unless the orchestrator itself crashed.
                    $completedNormally = $true
                    Write-WatchdogLog "STALE_AGENT_ORCH_SUBPROCESS agentId=$($agent.AgentId) — subprocess exited, normal" -Level INFO
                }
                if ($completedNormally) {
                    Write-Host "  Stale agent (completed): $($agent.AgentId) — cleaning" -ForegroundColor DarkGray
                } else {
                    $hasAgentOutput = (Test-Path (Join-Path $AgentDir "$($agent.AgentId).stdout")) -or
                        (Test-Path (Join-Path $AgentDir "$($agent.AgentId).stderr")) -or
                        (Test-Path (Join-Path $AgentDir "$($agent.AgentId).log"))
                    if ($hasAgentOutput) {
                        Save-CrashEvidence -AgentId $agent.AgentId -Label "normal-running"
                    } else {
                        Write-WatchdogLog "STALE_AGENT_ZOMBIE agentId=$($agent.AgentId) — cleaned without crash evidence (no output files)" -Level INFO
                    }
                    Write-Host "  Stale agent: $($agent.AgentId) — cleaning" -ForegroundColor Yellow
                }
            }
            Stop-SpawnedProcess -ProcessId ([int]$agent.PID) -Force
            Remove-Item (Join-Path $AgentDir "$($agent.AgentId).pid") -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $AgentDir "$($agent.AgentId).heartbeat") -Force -ErrorAction SilentlyContinue
        }
    }

    # ── Rogue agents (running >2h) ──────────────────────────────
    $rogueAgents = $fleet | Where-Object {
        $_.Status -eq "RUNNING" -and $_.Role -ne "orchestrator" -and $_.Elapsed -ne "-"
    } | Where-Object {
        if ($_.Elapsed -match '^(\d+)s$') { [int]$Matches[1] -gt 7200 }
        elseif ($_.Elapsed -match '^(\d+)m') { [int]$Matches[1] -gt 120 }
        else { $false }
    }
    if ($rogueAgents) {
        Write-Host "  Rogue agents (>2h runtime):" -ForegroundColor Yellow
        foreach ($agent in $rogueAgents) {
            Write-Host "    $($agent.AgentId) — $($agent.Elapsed)" -ForegroundColor Yellow
        }
    }

    # ── Proactive retry-budget check — quarantine files that exceeded budget ──
    # Only when orchestrator is NOT alive — prevents stealing active work
    $budgetPath = Join-Path $LogDir "file-retry-budget.json"
    if ($orchAlive) {
        # Orchestrator is running — decay retry budget by halving all retry counts
        # so that crash-recovery inflation doesn't cumulatively starve work
        if (Test-Path $budgetPath) {
            try {
                $budget = Get-Content $budgetPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($budget) {
                    $decayed = $false
                    foreach ($prop in $budget.PSObject.Properties) {
                        if ($prop.Value.retries -gt 0) {
                            $prop.Value.retries = [math]::Floor($prop.Value.retries / 2)
                            $decayed = $true
                        }
                    }
                    if ($decayed) {
                        $budget | ConvertTo-Json -Depth 5 | Set-Content $budgetPath -Encoding utf8 -NoNewline
                        Write-WatchdogLog "RETRY_BUDGET_DECAYED reason=orchestrator_alive" -Level INFO
                    }
                }
            } catch { Write-WatchdogLog "RETRY_BUDGET_DECAY_CHECK_FAILED error='$_'" -Level WARN }
        }
    } elseif (Test-Path $budgetPath) {
        try {
            $budget = Get-Content $budgetPath -Raw -Encoding utf8 -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        } catch { $budget = $null }
        if ($budget) {
            $quarantineDir = Join-Path $RepoDir "Tasks/Failed"
            $exceeded = $budget.PSObject.Properties | Where-Object { $_.Value.retries -ge 3 }
            foreach ($entry in $exceeded) {
                $fileName = $entry.Name
                $retries = $entry.Value.retries
                # Check both Code/ and Review/ for the file
                $found = $null
                foreach ($dir in @("Code", "Review")) {
                    $p = Join-Path $RepoDir "Tasks/$dir/$fileName"
                    try { $null = Get-Item -LiteralPath $p -ErrorAction Stop; $found = $p; break } catch { $found = $null }
                }
                if ($found) {
                    $null = New-Item -ItemType Directory -Path $quarantineDir -Force
                    Move-Item -LiteralPath $found -Destination (Join-Path $quarantineDir $fileName) -Force -ErrorAction SilentlyContinue
                    Write-WatchdogLog "FILE_QUARANTINED_PROACTIVE file=$fileName retries=$retries dir=$(Split-Path (Split-Path $found -Parent) -Leaf)" -Level WARN
                    Write-Host "  ✂ Quarantined $fileName (retries=$retries >= 3)" -ForegroundColor Yellow
                }
            }
        }
    }

    # ── No-progress detection with escalation ───────────────────
    # Exempt cycles where active agents have fresh heartbeats — they are
    # doing work even though queue counts haven't changed yet.
    $hasFreshAgentHeartbeat = $false
    if ($orchAlive -and $counts.Working -gt 0) {
        # Check orchestrator heartbeat (written to orchestrator-<InstanceId>.heartbeat)
        $orchHbFiles = Get-ChildItem "$AgentDir/orchestrator-*.heartbeat" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -ne 'orchestrator-detached' }
        foreach ($orchHbF in $orchHbFiles) {
            $orchHbContent = (Get-Content $orchHbF.FullName -Raw -ErrorAction SilentlyContinue).Trim()
            if ($orchHbContent) {
                $orchHbDate = $orchHbContent -as [datetime]
                if ($orchHbDate) {
                    $orchHbAge = [math]::Round(((Get-Date).ToUniversalTime() - $orchHbDate.ToUniversalTime()).TotalSeconds)
                    if ($orchHbAge -le 120) { $hasFreshAgentHeartbeat = $true; break }
                }
            }
        }
        # Also check lane/stream agent heartbeats
        if (-not $hasFreshAgentHeartbeat) {
            $agentHbFiles = Get-ChildItem "$AgentDir/lane-*.heartbeat","$AgentDir/stream-*.heartbeat" -ErrorAction SilentlyContinue
            foreach ($hbF in $agentHbFiles) {
                $hbContent = (Get-Content $hbF.FullName -Raw -ErrorAction SilentlyContinue).Trim()
                if ($hbContent) {
                    $hbDate = $hbContent -as [datetime]
                    if ($hbDate) {
                        $hbAge = [math]::Round(((Get-Date).ToUniversalTime() - $hbDate.ToUniversalTime()).TotalSeconds)
                        if ($hbAge -le 120) { $hasFreshAgentHeartbeat = $true; break }
                    }
                }
            }
        }
    }
    if ($previousQueueCounts) {
        $noProgress = ($counts.CoderWorkload -eq $previousQueueCounts.CoderWorkload) -and
                      ($counts.ReviewerWorkload -eq $previousQueueCounts.ReviewerWorkload) -and
                      ($counts.Working -eq $previousQueueCounts.Working)
        if (($noProgress -or $progressHealth.Stalled) -and -not $allEmpty) {
            if ($hasFreshAgentHeartbeat) {
                # Agents are actively working — don't count this as no-progress
                if ($consecutiveNoProgress -gt 0) {
                    Write-WatchdogLog "NO_PROGRESS_RESET reason=fresh_heartbeat cycle=$watchCycle consecutive=$consecutiveNoProgress" -Level INFO
                }
                $consecutiveNoProgress = 0
            } else {
                $consecutiveNoProgress++
                Write-Host "  No progress since last check (${consecutiveNoProgress}/${maxConsecutiveNoProgress}) — queues unchanged, no fresh heartbeats" -ForegroundColor Yellow
                Write-WatchdogLog "NO_PROGRESS cycle=$watchCycle code=$($counts.CoderWorkload) review=$($counts.ReviewerWorkload) working=$($counts.Working) consecutive=$consecutiveNoProgress freshHb=$hasFreshAgentHeartbeat" -Level WARN

                if ($consecutiveNoProgress -ge $maxConsecutiveNoProgress) {
                    Write-Host "  ⚠ No progress threshold reached — force-killing orchestrator" -ForegroundColor Red
                    Write-WatchdogLog "NO_PROGRESS_ESCALATION consecutive=$consecutiveNoProgress max=$maxConsecutiveNoProgress orchPid=$orchPid" -Level ERROR
                    if ($orchPid) {
                        # Only kill if registered in spawned-PID registry — never trust PID/file alone
                        Stop-ProcessTree -ProcessId $orchPid -Force
                        Start-Sleep -Seconds 3
                        $altPidFile = if (Test-Path $PidLockFile) { $PidLockFile } else { Get-OrchestratorPidFile }
                        $pidContent = if ($altPidFile) { (Get-Content $altPidFile -Raw -ErrorAction SilentlyContinue).Trim() } else { $null }
                        if ($pidContent) {
                            $altPid = $pidContent -as [int]
                            if ($altPid -and (Get-Process -Id $altPid -ErrorAction SilentlyContinue) -and $altPid -ne $PID) {
                                Stop-ProcessTree -ProcessId $altPid -Force
                            }
                        }
                        $orchInFleet = $fleet | Where-Object { $_.Role -eq "orchestrator" -and $_.Status -eq "RUNNING" } | Select-Object -First 1
                        if ($orchInFleet -and $orchInFleet.PID -ne $orchPid) {
                            Stop-ProcessTree -ProcessId ([int]$orchInFleet.PID) -Force
                        }
                    }
                    $consecutiveNoProgress = 0
                    continue
                }
            }
        } else {
            $consecutiveNoProgress = 0
        }
    }
    $previousQueueCounts = @{
        CoderWorkload   = $counts.CoderWorkload
        ReviewerWorkload = $counts.ReviewerWorkload
        Working         = $counts.Working
    }

    # ── Stop signal check ─────────────────────────────────────────
    $stopSignalPaths = @(
        (Join-Path $RepoDir "Tasks/stop.code"),
        (Join-Path $RepoDir "Tasks/stop.review"),
        (Join-Path $RepoDir "Tasks/stop"),
        (Join-Path $RepoDir "Tasks/Logs/.orchestrator-stop")
    )
    $signalFound = $stopSignalPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($signalFound) {
        Write-Host "Stop signal detected — exiting" -ForegroundColor Yellow
        break
    }
}

# ─── Cleanup ───────────────────────────────────────────────────────
if ((Get-WatchdogHealth).Pid -eq $PID) { Remove-Item $WatchdogPidFile -Force -ErrorAction SilentlyContinue }
Remove-Item $watchdogPidFile -Force -ErrorAction SilentlyContinue
Remove-Item $watchdogHbFile -Force -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $LogDir ".orchestrate-reload-count-*") -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
# Only clean crash evidence on success — preserve it on failure for RunFix investigation
if ($success) {
    try { Remove-Item (Join-Path $LogDir ".last-crash-evidence") -Force -ErrorAction SilentlyContinue } catch { Write-WatchdogLog "LAST_CRASH_EVIDENCE_CLEANUP_FAILED error='$_'" -Level WARN }
}

if ($success) {
    Write-WatchdogLog "WATCHDOG_EXIT reason=success"
    exit 0
}

try {
    $finalCounts = Get-TaskCounts
} catch {
    Write-WatchdogLog "FINAL_GET_TASK_COUNTS_FAILED error='$_' — using fallback" -Level WARN
    $finalCounts = [PSCustomObject]@{ CoderWorkload="?"; ReviewerWorkload="?"; Handoff="?"; Working="?"; Failed="?"; ToDo="?"; Manual="?"; Paused="?"; CompleteFiles="?"; CompleteDirs="?" }
}
Write-WatchdogLog "WATCHDOG_EXIT reason=failure code=$($finalCounts.CoderWorkload) review=$($finalCounts.ReviewerWorkload) handoff=$($finalCounts.Handoff) working=$($finalCounts.Working) re-launches=$recoveryCount" -Level WARN
Write-Host ""
Write-Host "Watchdog exited without detecting full success." -ForegroundColor Yellow
Write-Host "  Final queues: Code=$($finalCounts.CoderWorkload)  Review=$($finalCounts.ReviewerWorkload)  Handoff=$($finalCounts.Handoff)  Working=$($finalCounts.Working)  Failed=$($finalCounts.Failed)  ToDo=$($finalCounts.ToDo)  Manual=$($finalCounts.Manual)  Paused=$($finalCounts.Paused)  Complete=$($finalCounts.CompleteFiles)+$($finalCounts.CompleteDirs)" -ForegroundColor Yellow
Write-Host "  Re-launches:  $recoveryCount" -ForegroundColor Yellow
Write-Host "  Elapsed:      ${elapsedMin}m${elapsedSec}s" -ForegroundColor Yellow
exit 1
# TEST_MARKER
