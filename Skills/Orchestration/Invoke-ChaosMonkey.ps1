<#
.SYNOPSIS
    Chaos engineering suite for the orchestrator. Injects failures at
    configurable intervals and verifies invariants after recovery.
#>

function Invoke-ChaosMonkey {
    param(
        [string]$SandboxDir,
        [int]$KillIntervalSeconds = 30,
        [switch]$CorruptStream,
        [switch]$DeleteSentinel,
        [switch]$FakeStaleAgent,
        [switch]$NetworkHang
    )
    $logDir = Join-Path $SandboxDir "Tasks/Logs"
    $null = New-Item -ItemType Directory -Path $logDir -Force

    $orchestrator = Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile", "-NoLogo", "-File",
        (Join-Path $SandboxDir "Skills/Orchestration/LocalOrchestrator.ps1"),
        "-InterclawDir", $SandboxDir,
        "-SpawnMode", "Subprocess",
        "-CodeParallelCount", "2",
        "-MaxIterations", "20"
    ) -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $logDir "chaos-stdout.log") `
        -RedirectStandardError (Join-Path $logDir "chaos-stderr.log")

    $injections = @()
    if ($CorruptStream) { $injections += "corrupt-stream" }
    if ($DeleteSentinel) { $injections += "delete-sentinel" }
    if ($FakeStaleAgent) { $injections += "fake-stale-agent" }
    if ($NetworkHang) { $injections += "network-hang" }

    $workingDir = Join-Path $SandboxDir "Tasks/Working"
    $startTime = Get-Date
    $injectionIndex = 0

    do {
        Start-Sleep -Seconds $KillIntervalSeconds
        $elapsed = (Get-Date) - $startTime
        if ($elapsed.TotalSeconds -gt 120) { break }

        # Inject failure based on current index
        if ($injectionIndex -lt $injections.Count) {
            $injection = $injections[$injectionIndex]
            Write-Host "  CHAOS injecting=$injection" -ForegroundColor Magenta

            switch ($injection) {
                "corrupt-stream" {
                    $streamDirs = Get-ChildItem "$workingDir/stream-*" -Directory -ErrorAction SilentlyContinue
                    foreach ($sd in $streamDirs) {
                        $sj = Join-Path $sd.FullName "stream.json"
                        if (Test-Path $sj) {
                            Set-Content -Path $sj -Value "CORRUPTED" -Encoding utf8 -NoNewline
                        }
                    }
                }
                "delete-sentinel" {
                    $streamDirs = Get-ChildItem "$workingDir/stream-*" -Directory -ErrorAction SilentlyContinue
                    foreach ($sd in $streamDirs) {
                        $sc = Join-Path $sd.FullName ".complete"
                        if (Test-Path $sc) { Remove-Item $sc -Force -ErrorAction SilentlyContinue }
                    }
                }
                "fake-stale-agent" {
                    $agentDir = Join-Path $SandboxDir "Tasks/Logs/agents"
                    $null = New-Item -ItemType Directory -Path $agentDir -Force
                    Set-Content -Path (Join-Path $agentDir "chaos-fake-pid.pid") -Value "999999" -Encoding utf8 -NoNewline
                    Set-Content -Path (Join-Path $agentDir "chaos-fake-pid.heartbeat") -Value "2000-01-01T00:00:00Z" -Encoding utf8 -NoNewline
                }
                "network-hang" {
                    $hangDir = Join-Path $workingDir "stream-hang"
                    $null = New-Item -ItemType Directory -Path $hangDir -Force
                    Set-Content -Path (Join-Path $hangDir "stream.json") -Value '{"Id":"stream-hang","Namespace":"hang","Role":"coder"}' -Encoding utf8 -NoNewline
                    Set-Content -Path (Join-Path $hangDir "hang-plan.md") -Value "# Hang plan" -Encoding utf8 -NoNewline
                }
            }
            $injectionIndex++
        }

        if ($orchestrator.HasExited) { break }
    } while ($true)

    if (-not $orchestrator.HasExited) {
        Stop-ProcessTree -ProcessId $orchestrator.Id -Force
    }

    $invariants = Test-ChaosInvariants -SandboxDir $SandboxDir
    return $invariants
}

function Test-ChaosInvariants {
    param([string]$SandboxDir)
    $violations = [System.Collections.Generic.List[string]]::new()

    $codeFiles = Get-ChildItem "$SandboxDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue
    $reviewFiles = Get-ChildItem "$SandboxDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue
    $workingFiles = Get-ChildItem "$SandboxDir/Tasks/Working/*/*.md" -Recurse -ErrorAction SilentlyContinue

    # No file in Code/ should have Lock Header Status: locked
    foreach ($f in $codeFiles) {
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'Status:\s*locked') {
            $violations.Add("File '$($f.Name)' in Code/ has locked status")
        }
    }

    # No stream dir without .complete or active PID
    $streamDirs = Get-ChildItem "$SandboxDir/Tasks/Working/stream-*" -Directory -ErrorAction SilentlyContinue
    foreach ($sd in $streamDirs) {
        $hasComplete = Test-Path (Join-Path $sd.FullName ".complete")
        $streamJson = Join-Path $sd.FullName "stream.json"
        $hasStreamJson = Test-Path $streamJson
        if (-not $hasComplete -and $hasStreamJson) {
            try {
                $meta = Get-Content $streamJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            } catch { continue }
            $pidFile = Join-Path $SandboxDir "Tasks/Logs/agents/$($meta.Id).pid"
            $activePid = (Test-Path $pidFile) -and (Get-Process -Id ((Get-Content $pidFile -Raw).Trim()) -ErrorAction SilentlyContinue)
            if (-not $activePid) {
                $violations.Add("Stream '$($sd.Name)' has no .complete and no active PID")
            }
        }
    }

    return @{ Violations = $violations.Count; Details = $violations }
}

function Measure-ChaosSurvival {
    param([string]$SandboxDir)
    $intensities = @(30, 20, 10, 5)
    $curve = @()
    foreach ($intensity in $intensities) {
        $result = Invoke-ChaosMonkey -SandboxDir $SandboxDir -KillIntervalSeconds $intensity -CorruptStream -DeleteSentinel -FakeStaleAgent
        $survivalPct = if ($result.Violations -eq 0) { 100 } else { [math]::Max(0, 100 - ($result.Violations * 20)) }
        $curve += @{ intensity_seconds = $intensity; violations = $result.Violations; survival_pct = $survivalPct }
    }
    $curvePath = Join-Path $SandboxDir "Tasks/Logs/chaos-survival-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $curve | ConvertTo-Json -Depth 5 | Set-Content $curvePath -Encoding utf8 -NoNewline
    return $curve
}
