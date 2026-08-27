<#
.SYNOPSIS
    Waits for parallel build jobs to complete and reports results.
.DESCRIPTION
    Blocks until all jobs finish (or timeout), collects results with colour-coded
    output, and returns a summary hashtable. Removes jobs on completion.
.PARAMETER BuildContext
    Output hashtable from Start-ParallelImageBuild with Jobs and BuildLogDir keys.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for all jobs (default: 1800).
.OUTPUTS
    [hashtable] with Keys: Success (bool), Results (array), FailedBuilds (array).
#>
function Receive-ParallelImageBuild {
    [OutputType([bool])]
    param(
        [hashtable]$BuildContext,
        [int]$TimeoutSeconds = 1800
    )
    <#
    .NOTES
        Timeout chain: Inner Wait-Job -Timeout 30 poll loop within outer $TimeoutSeconds ceiling.
        30s < 1800s (default) ✅. Outer timeout enforced by $elapsed >= $TimeoutSeconds break.
    #>
    if (-not $BuildContext -or -not $BuildContext.ContainsKey("Jobs") -or -not $BuildContext.ContainsKey("BuildLogDir")) {
        throw "Receive-ParallelImageBuild: BuildContext must be a hashtable with 'Jobs' and 'BuildLogDir' keys."
    }

    $jobs = $BuildContext.Jobs
    $buildLogDir = $BuildContext.BuildLogDir

    if ($jobs.Count -eq 0) {
        Write-Information -MessageData "[BUILD] No build jobs to wait for." -Tags "INFO"
        return @{ Success = $true; Results = @(); FailedBuilds = @() }
    }

    Write-Information -MessageData "`n[BUILD] Waiting for $($jobs.Count) build job(s) to complete (timeout: ${TimeoutSeconds}s)..." -Tags "INFO"

    $startTime = Get-Date
    $runningJobs = @($jobs)
    $results = [System.Collections.ArrayList]::new()
    $failedBuilds = [System.Collections.ArrayList]::new()
    $succeededCount = 0

    while ($runningJobs.Count -gt 0) {
        $elapsed = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
        if ($elapsed -ge $TimeoutSeconds) {
            Write-Information -MessageData "[BUILD] Timeout after ${TimeoutSeconds}s -- stopping $($runningJobs.Count) remaining job(s)." -Tags "ERROR"
            break
        }

        $null = Wait-Job -Job $runningJobs -Timeout 30 -ErrorAction SilentlyContinue

        $completed = @($runningJobs | Where-Object { $_.State -ne 'Running' })
        $stillRunning = @($runningJobs | Where-Object { $_.State -eq 'Running' })

        foreach ($job in $completed) {
            $jobResult = $null

            $rawResult = Receive-Job $job
            if ($null -eq $rawResult) {
                $jobResult = @{ Name = $job.Name; Success = $false; Error = "Background job produced no output — job may have crashed (OOM or PowerShell crash)" }
            } elseif ($rawResult -is [hashtable]) {
                $jobResult = $rawResult
            } else {
                $jobResult = @{ Name = $job.Name; Success = $false; Error = "Unexpected job output: $($rawResult | Out-String)" }
            }

            if ($jobResult.Success) {
                $succeededCount++
                Write-Information -MessageData "  [OK] $($jobResult.Name) succeeded ($($jobResult.DurationMs) ms)" -Tags "INFO"
            } else {
                [void]$failedBuilds.Add($jobResult.Name)
                $errText = if ($jobResult.Error) { $jobResult.Error } else { "Unknown error" }
                Write-Information -MessageData "  [FAIL] $($jobResult.Name) FAILED: $errText" -Tags "ERROR"
                Write-SetupLog "Parallel build FAILED: $($jobResult.Name): $errText" -Level ERROR
                if ($buildLogDir -and (Test-Path $buildLogDir)) {
                    $logFile = Join-Path $buildLogDir "$($jobResult.Name).log"
                    if (Test-Path $logFile) {
                        Write-Information -MessageData "    Log: $logFile" -Tags "INFO"
                    }
                }
            }

            [void]$results.Add($jobResult)
            Remove-Job $job -ErrorAction SilentlyContinue
        }

        $runningJobs = $stillRunning

        if ($runningJobs.Count -gt 0) {
            $elapsed = [math]::Floor(((Get-Date) - $startTime).TotalSeconds)
            $elapsedM = [math]::Floor($elapsed / 60)
            $elapsedS = $elapsed % 60

            Write-Information -MessageData "[BUILD STATUS @ ${elapsedM}m${elapsedS}s] $($runningJobs.Count) still building:" -Tags "INFO"

            foreach ($j in $runningJobs) {
                $logFile = Join-Path $buildLogDir "$($j.Name).log"
                if (Test-Path $logFile) {
                    $lastLine = Get-Content -LiteralPath $logFile -Tail 3 -ErrorAction SilentlyContinue
                    if ($lastLine) {
                        $trimmed = ($lastLine | Out-String).Trim()
                        if ($trimmed) {
                            Write-Information -MessageData "    $($j.Name) log: $trimmed" -Tags "INFO"
                        }
                    }
                }
            }

            foreach ($j in $runningJobs) {
                $jobBegin = if ($null -ne $j.PSBeginTime -and $j.PSBeginTime -ne [DateTime]::MinValue) { $j.PSBeginTime } else { $startTime }
                $rawJobElapsed = [math]::Floor(((Get-Date) - $jobBegin).TotalSeconds)
                $jobElapsed = [Math]::Min($rawJobElapsed, $elapsed)
                $m = [math]::Floor($jobElapsed / 60)
                $s = $jobElapsed % 60
                Write-Information -MessageData "  $($j.Name)  ${m}m${s}s" -Tags "INFO"
            }
        }
    }

    # Handle timed-out jobs
    foreach ($job in $runningJobs) {
        Stop-Job $job
        $jobResult = @{ Name = $job.Name; Success = $false; Error = "Timed out after ${TimeoutSeconds}s" }
        [void]$failedBuilds.Add($jobResult.Name)
        Write-Information -MessageData "  [TIMEOUT] $($job.Name) timed out -- stopped." -Tags "ERROR"
        Write-SetupLog "Parallel build TIMEOUT: $($job.Name) exceeded ${TimeoutSeconds}s" -Level ERROR
        [void]$results.Add($jobResult)
        Remove-Job $job -ErrorAction SilentlyContinue
    }

    $allSucceeded = $failedBuilds.Count -eq 0

    Write-Information -MessageData "`n[BUILD] $succeededCount/$($jobs.Count) succeeded" -Tags "INFO"
    if ($failedBuilds.Count -gt 0) {
        $failedStr = $failedBuilds -join ", "
        Write-Information -MessageData "[BUILD] $($failedBuilds.Count) failed: $failedStr" -Tags "ERROR"
        Write-SetupLog "Parallel build: $succeededCount/$($jobs.Count) succeeded, $($failedBuilds.Count) failed: $failedStr" -Level ERROR
    } else {
        Write-SetupLog "Parallel build: all $($jobs.Count) succeeded"
    }

    if ($buildLogDir -and (Test-Path $buildLogDir)) {
        Get-ChildItem $buildLogDir -Filter "*.log" | ForEach-Object {
            Write-Information -MessageData "[BUILD LOG] $($_.FullName)" -Tags "INFO"
        }
    }

    return @{
        Success = $allSucceeded
        Results = $results.ToArray()
        FailedBuilds = $failedBuilds.ToArray()
    }
}

