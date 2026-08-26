# DEPRECATION NOTE — 2026-06-22
#
# This file provides a legacy per-agent lock-state tracking layer (held/waiting lock
# lists with deadlock detection via DFS cycle detection) that was never fully wired
# into the Lock-File/Unlock-File API.
#
# Status of each function:
#   LIVE (referenced externally):
#     Remove-LockHeld          — called by Public/Remove-NamespaceReservation.ps1:24
#     Get-LockState            — transitively needed by Remove-LockHeld
#     Write-LockState          — transitively needed by Remove-LockHeld
#     Invoke-WithLockStateMutex — transitively needed by Remove-LockHeld
#   DEPRECATED (no external references):
#     Get-AgentState           — orphaned
#     Add-LockHeld             — orphaned
#     Add-LockWaiting          — orphaned
#     Remove-LockWaiting       — orphaned
#     Test-Deadlock            — orphaned
#     Clear-LockState          — orphaned
#
# The deprecated functions are retained for compatibility in case a future iteration
# picks up multi-agent lock coordination. Do not add new callers.

<#
.SYNOPSIS
    Shared lock state tracker for deadlock detection across lock types.
.DESCRIPTION
    Provides functions to track which agent holds which locks (file, namespace)
    and which locks an agent is waiting for. The state is persisted to
    Tasks/Locks/lock-state.json with a named mutex for cross-process safety.
    Deadlock detection uses a DFS-based cycle check on the wait-for graph.
#>

$script:LockStatePath = $null
$script:LockStateMutexName = "Global\Interclaw-LockState"

function Get-LockState {
    <#
    .SYNOPSIS
        Reads the current lock state from the shared state file.
    .OUTPUTS
        Hashtable with an 'agents' key containing agent → lock entries.
    #>
    $repoRootFn = if (Get-Command Get-SalmonRunRepoRoot -ErrorAction SilentlyContinue) { 'Get-SalmonRunRepoRoot' } else { 'Get-InterclawRepoRoot' }
    $repoRoot = & (Get-Command $repoRootFn)
    $script:LockStatePath = Join-Path $repoRoot "Tasks" "Locks" "lock-state.json"
    if (Test-Path $script:LockStatePath) {
        try {
            $content = Get-Content -Path $script:LockStatePath -Raw -Encoding utf8 -ErrorAction Stop
            if ($content) {
                $state = $content | ConvertFrom-Json -ErrorAction Stop
                return $state
            }
        } catch {
            Write-Debug "Get-LockState: corrupted state file, backing up and returning empty state: $_"
            try {
                $backup = $script:LockStatePath + ".corrupt." + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Move-Item -LiteralPath $script:LockStatePath -Destination $backup -Force
            } catch { Write-Debug "Get-LockState: failed to backup corrupt state: $_" }
        }
    }
    return @{ agents = @{ } }
}

function Write-LockState {
    <#
    .SYNOPSIS
        Writes the lock state atomically to the shared state file.
    .PARAMETER State
        The state hashtable to persist.
    #>
    param([Parameter(Mandatory)]$State)
    $dir = Split-Path $script:LockStatePath -Parent
    $null = New-Item -ItemType Directory -Path $dir -Force
    $State | ConvertTo-Json -Compress -Depth 10 | Write-AtomicFile -Path $script:LockStatePath -Encoding utf8
}

function Invoke-WithLockStateMutex {
    <#
    .SYNOPSIS
        Acquires the lock-state mutex, executes a script block, and releases.
    .PARAMETER ScriptBlock
        Script block that receives the current state as $_.
    .OUTPUTS
        The return value of the script block.
    #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:LockStateMutexName)
        $timeoutMs = if ($env:PESTER_PROFILE) { 500 } else { 5000 }
        if (-not $mutex.WaitOne($timeoutMs)) {
            throw "Invoke-WithLockStateMutex: Mutex timeout after ${timeoutMs}ms"
        }
        $state = Get-LockState
        $result = & $ScriptBlock $state
        Write-LockState $state
        return $result
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { Write-Debug "LockState mutex release failed: $_" }
            $mutex.Dispose()
        }
    }
}

# DEPRECATED: No external callers. Retained for legacy compatibility.
function Get-AgentState {
    <#
    .SYNOPSIS
        Gets or creates the agent entry in the lock state.
    #>
    param([Parameter(Mandatory)][string]$AgentId, [Parameter(Mandatory)]$State)
    if (-not $State.agents.PSObject.Properties[$AgentId]) {
        $State.agents | Add-Member -NotePropertyName $AgentId -NotePropertyValue @{ held = @(); waiting = @() } -Force
    }
    return $State.agents.$AgentId
}

# DEPRECATED: No external callers. Retained for legacy compatibility.
function Add-LockHeld {
    <#
    .SYNOPSIS
        Records that an agent holds a lock.
    .PARAMETER AgentId
        Agent identifier.
    .PARAMETER LockType
        Type of lock: "file" or "namespace".
    .PARAMETER LockName
        Name of the locked resource (filename without extension, or namespace prefix).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$LockName
    )
    Invoke-WithLockStateMutex -ScriptBlock {
        param($state)
        $agent = Get-AgentState -AgentId $AgentId -State $state
        $entry = @{ type = $LockType; name = $LockName; ts = [datetime]::UtcNow.ToString('o') }
        $agent.held += $entry
        if ($agent.held.Count -gt 100) { $agent.held = $agent.held[-100..-1] }
    }
}

function Remove-LockHeld {
    <#
    .SYNOPSIS
        Records that an agent released a lock.
    .PARAMETER AgentId
        Agent identifier.
    .PARAMETER LockType
        Type of lock: "file" or "namespace".
    .PARAMETER LockName
        Name of the locked resource.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$LockName
    )
    Invoke-WithLockStateMutex -ScriptBlock {
        param($state)
        if (-not $state.agents.PSObject.Properties[$AgentId]) { return }
        $agent = $state.agents.$AgentId
        $agent.held = @($agent.held | Where-Object { -not ($_.type -eq $LockType -and $_.name -eq $LockName) })
        if ($agent.held.Count -eq 0 -and $agent.waiting.Count -eq 0) {
            $state.agents.PSObject.Properties.Remove($AgentId)
        }
    }
}

# DEPRECATED: No external callers. Retained for legacy compatibility.
function Add-LockWaiting {
    <#
    .SYNOPSIS
        Records that an agent is waiting for a lock.
    .PARAMETER AgentId
        Agent identifier.
    .PARAMETER LockType
        Type of lock: "file" or "namespace".
    .PARAMETER LockName
        Name of the locked resource.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$LockName
    )
    Invoke-WithLockStateMutex -ScriptBlock {
        param($state)
        $agent = Get-AgentState -AgentId $AgentId -State $state
        $entry = @{ type = $LockType; name = $LockName; ts = [datetime]::UtcNow.ToString('o') }
        $agent.waiting += $entry
        if ($agent.waiting.Count -gt 100) { $agent.waiting = $agent.waiting[-100..-1] }
    }
}

# DEPRECATED: No external callers. Retained for legacy compatibility.
function Remove-LockWaiting {
    <#
    .SYNOPSIS
        Records that an agent is no longer waiting for a lock.
    .PARAMETER AgentId
        Agent identifier.
    .PARAMETER LockType
        Type of lock: "file" or "namespace".
    .PARAMETER LockName
        Name of the locked resource.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$LockName
    )
    Invoke-WithLockStateMutex -ScriptBlock {
        param($state)
        if (-not $state.agents.PSObject.Properties[$AgentId]) { return }
        $agent = $state.agents.$AgentId
        $agent.waiting = @($agent.waiting | Where-Object { -not ($_.type -eq $LockType -and $_.name -eq $LockName) })
        if ($agent.held.Count -eq 0 -and $agent.waiting.Count -eq 0) {
            $state.agents.PSObject.Properties.Remove($AgentId)
        }
    }
}

# DEPRECATED: No external callers. Retained for legacy compatibility.
function Test-Deadlock {
    <#
    .SYNOPSIS
        Checks if granting a lock to an agent would create a deadlock in the wait-for graph.
    .DESCRIPTION
        Builds a wait-for graph from the current lock state and simulates adding
        edges from the requesting agent to all holders of the requested lock.
        Runs DFS from the requesting agent — if it reaches itself, a cycle exists.
    .PARAMETER AgentId
        Agent requesting the lock.
    .PARAMETER LockType
        Type of lock: "file" or "namespace".
    .PARAMETER LockName
        Name of the locked resource.
    .OUTPUTS
        $true if a deadlock would be created, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$AgentId,
        [Parameter(Mandatory)][string]$LockType,
        [Parameter(Mandatory)][string]$LockName
    )
    return Invoke-WithLockStateMutex -ScriptBlock {
        param($state)
        $agents = $state.agents.PSObject.Properties.Name
        if (-not $agents -or $agents.Count -eq 0) { return $false }

        # Build wait-for graph: who is waiting for whom
        # waitGraph[A] = @(agent ids that A is waiting for)
        $waitGraph = @{}

        # Also build: which agents hold which locks
        # lockHolders["type:name"] = @(agent ids)
        $lockHolders = @{}

        foreach ($agentName in $agents) {
            $agentState = $state.agents.$agentName
            $waitGraph[$agentName] = @()

            # Record held locks
            foreach ($held in $agentState.held) {
                $key = "$($held.type):$($held.name)"
                if (-not $lockHolders.ContainsKey($key)) { $lockHolders[$key] = @() }
                $lockHolders[$key] += $agentName
            }

            # Record wait-for edges: agent waits for lock X, all holders of X are wait targets
            foreach ($waiting in $agentState.waiting) {
                $key = "$($waiting.type):$($waiting.name)"
                if ($lockHolders.ContainsKey($key)) {
                    foreach ($holder in $lockHolders[$key]) {
                        if ($holder -ne $agentName) {
                            $waitGraph[$agentName] += $holder
                        }
                    }
                }
            }
        }

        # Now add prospective edges: requesting agent → holders of requested lock
        $requestedKey = "$($LockType):$LockName"
        $waitGraph[$AgentId] = @()
        if ($lockHolders.ContainsKey($requestedKey)) {
            foreach ($holder in $lockHolders[$requestedKey]) {
                if ($holder -ne $AgentId) {
                    $waitGraph[$AgentId] += $holder
                }
            }
        }

        # DFS from AgentId to detect cycle
        $visited = @{}
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($AgentId)

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            if ($visited.ContainsKey($current)) { continue }
            $visited[$current] = $true
            foreach ($neighbor in $waitGraph[$current]) {
                if ($neighbor -eq $AgentId) { return $true }
                if (-not $visited.ContainsKey($neighbor)) {
                    $stack.Push($neighbor)
                }
            }
        }

        return $false
    }
}

# DEPRECATED: No external callers. Retained for legacy compatibility.
function Clear-LockState {
    <#
    .SYNOPSIS
        Clears all lock state entries for a given agent (cleanup on exit).
    .PARAMETER AgentId
        Agent identifier to clear.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$AgentId
    )
    Invoke-WithLockStateMutex -ScriptBlock {
        param($state)
        if ($state.agents.PSObject.Properties[$AgentId]) {
            $state.agents.PSObject.Properties.Remove($AgentId)
        }
    }
}
