function Invoke-PondTaskMonitorStream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,
        [Parameter(Mandatory)]
        [PondTask]$Task,
        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $group = $Context.CurrentGroup
    if (-not $group) { $Context.Continue = $false; return $Context }
    if ($Context.Config -and $Context.Config.PSObject.Properties['DecisionRequired'] -and $Context.Config.DecisionRequired) {
        $Context.Success = $false
        return $Context
    }

    $lanePath = $group.StreamPath
    if ([string]::IsNullOrWhiteSpace($lanePath)) {
        $Context.Continue = $false
        return $Context
    }

    $completeFile = Join-Path $lanePath '.complete'
    $failedFile = Join-Path $lanePath '.failed'

    $timeoutMinutes = 30
    if ($Context.Config -and $null -ne $Context.Config.TimeoutMinutes) {
        $timeoutMinutes = $Context.Config.TimeoutMinutes
    }
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)

    $pollSeconds = 5
    $Context.Success = $false

    $pidFile = Join-Path $lanePath '.pid'
    $processId = $null
    if (Test-Path -LiteralPath $pidFile) {
        $pidText = Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue
        $null = [int]::TryParse($pidText, [ref]$processId)
    }

    # If sentinels already exist, return immediately.
    if (Test-Path -LiteralPath $completeFile) {
        Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' completed"
        $Context.Success = $true
        return $Context
    }
    if (Test-Path -LiteralPath $failedFile) {
        Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' reported failure"
        $Context.Success = $false
        return $Context
    }

    $pidGoneCount = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $pollSeconds
        if (Test-Path -LiteralPath $completeFile) {
            Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' completed"
            $Context.Success = $true
            break
        }
        if (Test-Path -LiteralPath $failedFile) {
            Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' reported failure"
            $Context.Success = $false
            break
        }

        # Defensive stale-PID check: if the tracked process is gone and no
        # sentinel was written, declare a failure so the lane can be retried.
        if ($processId -and -not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) {
            $pidGoneCount++
            if ($pidGoneCount -ge 2) {
                Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' process $processId gone without sentinel; marking failed"
                '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline
                $Context.Success = $false
                break
            }
        } else {
            $pidGoneCount = 0
        }
    }

    if (-not $Context.Success -and -not (Test-Path -LiteralPath $completeFile)) {
        Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' timed out or failed"
        # Force-kill the tracked child and its descendants so a long-running agent
        # cannot continue modifying files or hold locks after the pond deadline.
        if ($processId) {
            $null = taskkill /T /F /PID $processId 2>&1 | Out-Null
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $failedFile)) {
            '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline
        }
    }

    return $Context
}

