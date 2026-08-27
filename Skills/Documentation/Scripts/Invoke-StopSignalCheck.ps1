function Invoke-StopSignalCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Mode,

        [string]$AgentId = $script:agentId,

        [int]$ThisPid = $PID,

        [string]$SignalDir = "Tasks",

        [switch]$SkipOrchestratorActive
    )

    $modeFile = Join-Path $SignalDir "stop.$Mode"
    $globalFile = Join-Path $SignalDir "stop"

    # Orchestrator-active signal — standalone agents yield when an orchestrator is running.
    # Stream agents have $env:OC_STREAM_ID set and skip this check.
    if (-not $SkipOrchestratorActive -and -not $env:OC_STREAM_ID) {
        $orchActivePath = Join-Path $SignalDir "Logs" ".orchestrator-active"
        if (Test-Path -LiteralPath $orchActivePath) {
            $orchContent = Get-Content $orchActivePath -Raw -ErrorAction SilentlyContinue
            if ($orchContent) {
                $lines = $orchContent.Trim() -split "`n"
                $orchPid = if ($lines.Count -ge 1) { $lines[0].Trim() -as [int] } else { $null }
                if ($orchPid -and (Get-Process -Id $orchPid -ErrorAction SilentlyContinue)) {
                    # Orchestrator is actively running — yield
                    if (Get-Command Write-WorkflowEvent -ErrorAction SilentlyContinue) {
                        Write-WorkflowEvent -Type CLEANUP -Detail "orchestrator-active (PID $orchPid) — yielding" -Phase $Mode
                    }
                    return $true
                }
                # Orchestrator PID is dead — clean stale file
                Remove-Item -LiteralPath $orchActivePath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 1. Mode-specific persistent signal
    # Every agent that checks sees the signal — it is NOT deleted here.
    # Cleanup is handled by the orchestrator at startup (Clear-StaleOrchestratorFiles)
    # or by the entity that created the signal.
    if (Test-Path -LiteralPath $modeFile) {
        if (Get-Command Write-WorkflowEvent -ErrorAction SilentlyContinue) {
            Write-WorkflowEvent -Type CLEANUP -Detail "stop-signal-received (mode: $Mode)" -Phase $Mode
        }
        return $true
    }

    # 2. Global stop — PID-based self-cleaning
    if (Test-Path -LiteralPath $globalFile) {
        "$AgentId|$ThisPid|$Mode" | Add-Content -Path $globalFile -Encoding utf8

        $allEntries = Get-Content -LiteralPath $globalFile
        $othersAlive = $false

        foreach ($line in $allEntries) {
            $parts = $line.Split('|')
            if ($parts.Count -lt 2) { continue }
            $otherPid = $parts[1] -as [int]
            if ($otherPid -eq $ThisPid) { continue }

            $alive = $false
            # Try OS process check first (same-machine agents)
            if (Get-Process -Id $otherPid -ErrorAction SilentlyContinue) {
                $alive = $true
            } else {
                # Cross-container fallback: check heartbeat freshness
                $hbFile = Join-Path $SignalDir "Logs" "agents" "$($parts[0]).heartbeat"
                if (Test-Path -LiteralPath $hbFile) {
                    $stale = ((Get-Date) - (Get-Item $hbFile).LastWriteTime).TotalMinutes -gt 5
                    if (-not $stale) { $alive = $true }
                }
            }
            if ($alive) { $othersAlive = $true; break }
        }

        if (-not $othersAlive) {
            Remove-Item -LiteralPath $globalFile -Force
        }

        if (Get-Command Write-WorkflowEvent -ErrorAction SilentlyContinue) {
            Write-WorkflowEvent -Type CLEANUP -Detail "stop-signal-received (global)" -Phase $Mode
        }
        return $true
    }

    return $false
}

# If invoked directly (not dot-sourced), run with bound parameters.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\.\s') {
    Invoke-StopSignalCheck @PSBoundParameters
}
