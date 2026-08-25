<#
.SYNOPSIS
    Locks one or more files by creating exclusive lock files with timeout and rollback.
.DESCRIPTION
    Creates .lock files under Tasks/Locks/ for each specified filename. If a
    lock cannot be acquired, retries until the deadline (MaxWaitMs). On timeout,
    releases any locks already held and returns $false.
    Alias: Acquire-FileLock

LOCKING CONVENTION
    All named synchronization primitives in this codebase MUST use the
    Global\ prefix to ensure cross-session compatibility on Windows:
    - New-Object System.Threading.Mutex($false, "Global\Interclaw-*")
    - New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-*")

    Without the Global\ prefix, the mutex/semaphore is session-scoped
    and will silently fail under non-interactive sessions (scheduled
    tasks, service accounts, containers running under different session
    affinity). See SalmonRun.DeployState.ps1 and SalmonRun.Secrets.psm1
    for correct examples.

    File-based locks (this function) do not need the Global\ prefix as
    they use NTFS paths which are inherently system-wide.
.PARAMETER FileNames
    One or more filenames to lock (without extension).
.PARAMETER MaxWaitMs
    Maximum total wait time in milliseconds. Default 5000.
.OUTPUTS
    $true if all locks were acquired, $false on timeout.
#>
function Lock-File {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string[]]$FileNames,

        [int]$MaxWaitMs = 5000
    )

    $repoRoot = Get-InterclawRepoRoot
    $locksDir = Join-Path $repoRoot "Tasks" "Locks"
    $null = New-Item -ItemType Directory -Path $locksDir -Force

    if (-not $FileNames -or $FileNames.Count -eq 0) { return $true }

    $acquired = [System.Collections.Generic.List[string]]::new()
    $deadline = [datetime]::UtcNow.AddMilliseconds($MaxWaitMs)
    $myPid = $PID
    $myAgentId = if ($script:agentId) { $script:agentId } else { "unknown" }
    $lockContent = "$myAgentId|$myPid|$(Get-Date -Format 'o')"

    while ([datetime]::UtcNow -lt $deadline) {
        $acquired.Clear()
        $allSucceeded = $true

        foreach ($name in $FileNames) {
            $lockPath = Join-Path $locksDir "$name.lock"
            $acquiredHere = $false
            try {
                $null = New-Item -ItemType File -Path $lockPath -Value $lockContent -ErrorAction Stop
                $acquiredHere = $true
            } catch [System.IO.IOException] {
                # Lock exists — check for staleness
                try {
                    $existing = Get-Content -LiteralPath $lockPath -Raw -ErrorAction Stop
                    $parts = ($existing.Trim() -split '\|')
                    if ($parts.Count -ge 3) {
                        $otherPid = $parts[1] -as [int]
                        $otherTimestamp = try { [datetime]::Parse($parts[2], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $null }
                        $otherAlive = $false
                        if ($otherPid -and (Get-Process -Id $otherPid -ErrorAction SilentlyContinue)) {
                            $otherAlive = $true
                        }
                        # Reclaim if PID is dead OR lock is older than 10 minutes regardless of PID liveness
                        if (($otherAlive -and $otherTimestamp -and (([datetime]::UtcNow) - $otherTimestamp.ToUniversalTime()).TotalMinutes -gt 10)) {
                            $otherAlive = $false
                        }
                        if (-not $otherAlive) {
                            Remove-Item -Path $lockPath -Force -ErrorAction SilentlyContinue
                            try {
                                $null = New-Item -ItemType File -Path $lockPath -Value $lockContent -ErrorAction Stop
                                $acquiredHere = $true
                            } catch {
                                Write-Debug "Lock-File: raced with another writer on $lockPath : $_"
                            }
                        }
                    }
                } catch {
                    Write-Debug "Lock-File: cannot read lock file $lockPath : $_"
                }
            } catch {
                foreach ($path in $acquired) {
                    Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
                }
                throw
            }
            if ($acquiredHere) {
                $acquired.Add($lockPath)
            } else {
                $allSucceeded = $false
                break
            }
        }

        if ($allSucceeded) { return $true }

        foreach ($path in $acquired) {
            Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }

        if ([datetime]::UtcNow -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 200
    }

    return $false
}
