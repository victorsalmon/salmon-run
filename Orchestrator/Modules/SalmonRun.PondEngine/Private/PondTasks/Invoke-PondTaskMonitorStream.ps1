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
    }

    if (-not $Context.Success -and -not (Test-Path -LiteralPath $completeFile)) {
        Write-Verbose "Invoke-PondTaskMonitorStream: group '$($group.Namespace)' timed out or failed"
    }

    return $Context
}
