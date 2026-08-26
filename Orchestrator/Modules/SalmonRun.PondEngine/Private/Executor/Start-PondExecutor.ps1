function Start-PondExecutor {
    <#
    .SYNOPSIS
        Starts the selected executor for a pond group and waits for it to finish.

        The command can be supplied either as a raw string in $Command.Command
        (run through the system shell) or as a structured $Command.StartInfo
        with FilePath and ArgumentList. When the process exits the function
        writes a .complete sentinel for exit code 0, or a .failed sentinel for
        any other outcome. This lets the monitor task detect completion
        immediately.

        If $Command.Credentials is populated and SalmonRun.Credentials is
        available, each named credential is resolved from ~/.salmon/.env and
        injected into the child process environment. Values are restored after
        the run so they are not left in the parent session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Command,

        [Parameter(Mandatory)]
        [string]$LanePath,

        [string]$LogPath
    )

    $ErrorActionPreference = 'Continue'

    $runFile = Join-Path $LanePath '.run'
    $Command | ConvertTo-Json -Depth 2 | Set-Content -LiteralPath $runFile -Encoding utf8 -NoNewline

    $pidFile = Join-Path $LanePath '.pid'
    $logDir = if ($LogPath) { Split-Path -Parent $LogPath } else { $LanePath }
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue

    # Prefer a structured StartInfo (FilePath + ArgumentList). Fall back to a
    # shell invocation of the raw $Command.Command string for compatibility.
    $startInfo = if ($Command.PSObject.Properties['StartInfo']) { $Command.StartInfo } else { $null }
    if ($startInfo -and $startInfo.PSObject.Properties['FilePath'] -and $startInfo.FilePath) {
        $filePath = $startInfo.FilePath
        $argumentList = @($startInfo.ArgumentList)
        $shellCommand = $null
    } else {
        $filePath = if ($IsWindows -or ($PSVersionTable.Platform -eq 'Win32NT')) { 'cmd.exe' } else { '/bin/sh' }
        $shellFlag = if ($IsWindows -or ($PSVersionTable.Platform -eq 'Win32NT')) { '/c' } else { '-c' }
        $argumentList = @($shellFlag, $Command.Command)
        $shellCommand = $Command.Command
    }

    $outFile = if ($LogPath) { $LogPath } else { Join-Path $LanePath 'executor.log' }
    $errFile = "$outFile.err"

    $timeoutMinutes = if ($Command.PSObject.Properties['TimeoutMinutes'] -and $Command.TimeoutMinutes) { $Command.TimeoutMinutes } else { 30 }

    # Resolve credentials and backup current process values so we can restore.
    $envBackup = @{}
    $credentialNames = if ($Command.PSObject.Properties['Credentials']) { [string[]](@($Command.Credentials | Where-Object { $_ -ne $null })) } else { [string[]]@() }
    if ($credentialNames -and (Get-Command Get-SalmonRunCredential -ErrorAction SilentlyContinue)) {
        $salmonHome = if (Get-Command Get-SalmonHome -ErrorAction SilentlyContinue) { Get-SalmonHome } else { Join-Path $HOME '.salmon' }
        $envPath = Join-Path $salmonHome '.env'
        foreach ($name in $credentialNames) {
            $value = $null
            try { $value = Get-SalmonRunCredential -Name $name -EnvPath $envPath } catch { }
            if ($null -ne $value) {
                $envBackup[$name] = if (Test-Path "Env:\$name") { (Get-Item "Env:\$name").Value } else { $null }
                [Environment]::SetEnvironmentVariable($name, $value, 'Process')
            }
        }
    }

    $proc = $null
    $exitCode = -1
    try {
        $proc = Start-Process -FilePath $filePath -ArgumentList $argumentList `
            -WorkingDirectory $Command.RepoDir `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -NoNewWindow -PassThru -ErrorAction Stop

        $pidContent = if ($proc) { $proc.Id.ToString() } else { '0' }
        $pidContent | Set-Content -LiteralPath $pidFile -Encoding utf8 -NoNewline

        $deadline = (Get-Date).AddMinutes($timeoutMinutes)
        while ((Get-Date) -lt $deadline -and $proc -and -not $proc.HasExited) {
            Start-Sleep -Seconds 1
        }

        if ($proc -and -not $proc.HasExited) {
            Write-Verbose "Start-PondExecutor: timeout ($timeoutMinutes min) for role '$($Command.Role)'; stopping process $($proc.Id)"
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $exitCode = -2
        } else {
            if ($proc) {
                # Give the process a moment to settle its exit code.
                Start-Sleep -Milliseconds 500
                $exitCode = $proc.ExitCode
            }
        }

        # Append any captured stderr to the main log for convenience.
        if (Test-Path -LiteralPath $errFile) {
            $errText = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
            if ($errText) {
                "`n--- stderr ---`n$errText" | Add-Content -LiteralPath $outFile -Encoding utf8 -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Verbose "Start-PondExecutor: failed to start process for role '$($Command.Role)': $($_.Exception.Message)"
        $exitCode = -1
        "ERROR: $($_.Exception.Message)" | Set-Content -LiteralPath $errFile -Encoding utf8 -NoNewline
    } finally {
        # Restore the process environment before writing sentinels.
        foreach ($name in $envBackup.Keys) {
            $old = $envBackup[$name]
            if ($null -eq $old) {
                Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $old, 'Process')
            }
        }

        $completeFile = Join-Path $LanePath '.complete'
        $failedFile = Join-Path $LanePath '.failed'
        if ($exitCode -eq 0) {
            '1' | Set-Content -LiteralPath $completeFile -Encoding utf8 -NoNewline
        } else {
            $exitCode | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline
        }
    }

    Write-Verbose "Start-PondExecutor: role '$($Command.Role)' finished with exit $exitCode"
    return ($Command | Select-Object *, @{N='ExitCode';E={$exitCode}})
}
