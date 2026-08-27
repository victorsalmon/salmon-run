# Stream Agent Tracker — monitors all stream agents and their exit codes
param([int]$PollSeconds = 60, [int]$MaxRuns = 120)
$InterclawDir = "C:\Users\Victor\intersite-orchestrator"
$logFile = Join-Path $InterclawDir "Tasks\Logs\stream-tracker.log"
$agentDir = Join-Path $InterclawDir "Tasks\Logs\agents"
$workingDir = Join-Path $InterclawDir "Tasks\Working"
$tracked = @{}   # streamId -> @{ status, exitCode, elapsed, file, role }

function Log { param($Msg) $line = "[$(Get-Date -Format 'HH:mm:ss')] $Msg"; Add-Content -Path $logFile -Value $line -Encoding utf8 }

function Get-StreamStatusFromStdout {
    param([string]$StreamId)
    $stdout = Join-Path $agentDir "$StreamId.stdout"
    $stderr = Join-Path $agentDir "$StreamId.stderr"
    if (-not (Test-Path $stdout)) { return $null }
    $content = Get-Content $stdout -Raw -ErrorAction SilentlyContinue
    $pidFile = Join-Path $agentDir "$StreamId.pid"
    $procAlive = $false
    if (Test-Path $pidFile) {
        $storedPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($storedPid) { $procAlive = [bool](Get-Process -Id $storedPid -ErrorAction SilentlyContinue) }
    }
    $status = "running"
    $exitCode = -1
    $completedFile = $null
    if ($content -match 'Status: Completed `(.+?)`') { $status = "completed"; $completedFile = $Matches[1]; $exitCode = 0 }
    elseif ($content -match 'EXIT idle_timeout') { $status = "idle-timeout"; $exitCode = 0 }
    elseif ($content -match 'COMMIT.*hash=(\w+)') { $status = "committed" }
    elseif (-not $procAlive) { $status = "crashed"; $exitCode = -1 }
    $hbFile = Join-Path $agentDir "$StreamId.heartbeat"
    $hbAge = -1
    if (Test-Path $hbFile) {
        $hb = (Get-Content $hbFile -Raw -ErrorAction SilentlyContinue).Trim() -as [datetime]
        if ($hb) { $hbAge = [math]::Round((([datetime]::UtcNow) - $hb.ToUniversalTime()).TotalMinutes, 0) }
    }
    return @{ Status = $status; ExitCode = $exitCode; File = $completedFile; HeartbeatAge = $hbAge; ProcAlive = $procAlive }
}

Log "STREAM_TRACKER_START pollSeconds=$PollSeconds"

for ($run = 1; $run -le $MaxRuns; $run++) {
    $streamDirs = Get-ChildItem "$workingDir\stream-*" -Directory -ErrorAction SilentlyContinue
    $agentStdouts = Get-ChildItem "$agentDir\stream-*.stdout" -ErrorAction SilentlyContinue

    # Get current file in each stream dir
    $activeFiles = @{}
    foreach ($d in $streamDirs) {
        $f = Get-ChildItem "$($d.FullName)\*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { $activeFiles[$d.Name] = $f.Name }
    }

    $line = ""
    foreach ($s in ($agentStdouts | Sort-Object Name)) {
        $streamId = $s.BaseName
        $info = Get-StreamStatusFromStdout -StreamId $streamId
        $file = if ($activeFiles[$streamId]) { $activeFiles[$streamId] } else { "-" }
        if ($info.Status -eq "running") {
            $proc = if ($info.ProcAlive) { "A" } else { "Z" }
            $hb = if ($info.HeartbeatAge -ge 0) { "${hb}m" } else { "?" }
            $line += "$streamId($proc$($hb):$file) "
        }
    }

    # Completed streams (track from stdout detection)
    foreach ($s in ($agentStdouts | Sort-Object Name)) {
        $streamId = $s.BaseName
        if (-not $tracked.ContainsKey($streamId)) {
            $info = Get-StreamStatusFromStdout -StreamId $streamId
            if ($info.Status -ne "running") {
                $tracked[$streamId] = $info
                Log "EXIT $streamId status=$($info.Status) exitCode=$($info.ExitCode) file=$($info.File)"
            }
        }
    }

    $code = @(Get-ChildItem (Join-Path $InterclawDir "Tasks\Code\*.md") -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    $review = @(Get-ChildItem (Join-Path $InterclawDir "Tasks\Review\*.md") -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
    Write-Host "[$run] Code $code | Review $review | $(if($line -eq ''){'idle'}else{$line})"

    if ($run -eq $MaxRuns) {
        Log "STREAM_TRACKER_EXIT tracked=$($tracked.Count) completed=$(@($tracked.Values | Where-Object { $_.Status -eq 'completed' }).Count) crashed=$(@($tracked.Values | Where-Object { $_.Status -eq 'crashed' }).Count) idle=$(@($tracked.Values | Where-Object { $_.Status -eq 'idle-timeout' }).Count)"
        Write-Host "`n=== Tracked Stream Summary ===" -ForegroundColor Cyan
        $tracked.Keys | Sort-Object | ForEach-Object {
            $t = $tracked[$_]
            $icon = switch ($t.Status) { 'completed' { '✓' } 'crashed' { '✗' } 'idle-timeout' { '⏭' } default { '?' } }
            Write-Host "  $icon $_ : exit=$($t.ExitCode) file=$($t.File)"
        }
    }

    Start-Sleep -Seconds $PollSeconds
}
