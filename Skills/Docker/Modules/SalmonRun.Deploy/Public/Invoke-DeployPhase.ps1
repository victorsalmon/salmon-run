<#
.SYNOPSIS
    Invokes a deploy phase with mutex-guarded checkpoint tracking.
.DESCRIPTION
    Runs a phase script block, records completion to checkpoint file, and
    returns the updated list of completed phases. Supports WhatIf, TagOnly,
    and dependency-based skip logic.
#>
function Invoke-DeployPhase {
    param(
        [Alias('Phase')]
        [string]$PhaseName,
        [scriptblock]$ScriptBlock,
        [switch]$Recoverable,
        [hashtable]$PhaseDependencies,
        [string[]]$CompletedPhases,
        [string]$SelectedPhase,
        [switch]$TagOnly,
        [switch]$WhatIf,
        [string]$PSScriptRoot
    )

    $mutexName = "Global\Interclaw-DeployPhase-Mutex"

    $mutex1 = $null
    try {
        $mutex1 = New-Object System.Threading.Mutex($false, $mutexName)
        if (-not $mutex1.WaitOne(30000)) {
            throw "Invoke-DeployPhase: Mutex timeout after 30000ms -- concurrent access detected"
        }

        $checkpointFile = if ($PSScriptRoot) { Join-Path $PSScriptRoot ".deploy-checkpoint.json" } else { $null }
        $cachedCompletedPhases = @($CompletedPhases)
        if ($checkpointFile -and (Test-Path $checkpointFile)) {
            try {
                $cp = Get-Content $checkpointFile -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($cp.completed_phases) {
                    $cachedCompletedPhases = @($cp.completed_phases)
                }
            } catch {
                Write-SetupLog "Failed to read deploy checkpoint: $_" -Level WARN
            }
        }
    } finally {
        if ($mutex1) {
            try { $null = $mutex1.ReleaseMutex() } catch { Write-Debug "Invoke-DeployPhase: mutex1 release failed for phase '$PhaseName': $_" }
            $mutex1.Dispose()
        }
    }

    if ($SelectedPhase -and $SelectedPhase -ne $PhaseName) { return $cachedCompletedPhases }
    if (-not (Test-DeployPhasePrerequisites -PhaseName $PhaseName -PhaseDependencies $PhaseDependencies -CompletedPhases $cachedCompletedPhases)) { return $cachedCompletedPhases }
    if ($WhatIf) {
        Write-Information -MessageData "  WOULD: Execute phase '$PhaseName'" -Tags "WARN"
        return $cachedCompletedPhases
    }
    if ($TagOnly) {
        Write-Information -MessageData "  [SKIP] Phase '$PhaseName' skipped (TagOnly mode)" -Tags "WARN"
    } else {
        $params = @{ Phase = $PhaseName; ScriptBlock = $ScriptBlock }
        if ($Recoverable) { $params.Recoverable = $true }
        Write-SetupLog "Invoking phase: $PhaseName"
        SalmonRun.DeployState\Invoke-DeployStatePhase @params
    }

    $completedPhases = $cachedCompletedPhases + $PhaseName

    $mutex2 = $null
    try {
        $mutex2 = New-Object System.Threading.Mutex($false, $mutexName)
        if (-not $mutex2.WaitOne(30000)) {
            throw "Invoke-DeployPhase: Mutex timeout after 30000ms for checkpoint write"
        }
        $checkpointData = @{
            completed_phases = @($completedPhases)
            last_phase = $PhaseName
            timestamp = (Get-Date).ToString('o')
            run_id = $env:INTERCLAW_RUN_ID
        }
        if ($checkpointFile) {
            $checkpointData | ConvertTo-Json | Write-AtomicFile -Path $checkpointFile -Encoding utf8
        }
    } catch {
        Write-SetupLog "Failed to write checkpoint file: $_" -Level WARN
    } finally {
        if ($mutex2) {
            try { $null = $mutex2.ReleaseMutex() } catch { Write-Debug "Invoke-DeployPhase: mutex2 release failed for phase '$PhaseName': $_" }
            $mutex2.Dispose()
        }
    }
    return $completedPhases
}
