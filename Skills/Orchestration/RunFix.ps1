<#
.SYNOPSIS
    Detached RunFix engine — run any script iteratively, diagnosing and fixing errors.
.DESCRIPTION
    Launches the target in the background and polls every $PollIntervalSeconds
    (default 60) to check rubrics against partial output. If fatal failures are
    detected mid-run, the process is killed, root-cause diagnosed, fixed,
    committed/pushed, and re-launched. Continues for up to $runfixMaxWallMinutes
    (default 720 = 12 hours). No cycle limit. Uses `opencode run --command fix-diagnose`
    only for the LLM-required step (error diagnosis + source fix).
.PARAMETER GoalsFile
    Path to the .md goals file (e.g. Skills/Workflows/RunFix/runfix-deploy.md)
.PARAMETER PollIntervalSeconds
    Interval in seconds between rubric checks while target runs. Default 60.
.PARAMETER ExtraArgs
    Extra arguments to pass to the target script.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$GoalsFile,
    [int]$PollIntervalSeconds = 60,
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Stop"
$sessionStart = Get-Date
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runfixPid = $PID
$runfixTimeoutSec = if ($env:RUNFIX_TIMEOUT_SECONDS) { [int]$env:RUNFIX_TIMEOUT_SECONDS } else { 300 }
$runfixMaxWallMinutes = if ($env:RUNFIX_MAX_WALL_MINUTES) { [int]$env:RUNFIX_MAX_WALL_MINUTES } else { 720 }

# --- Repo root resolution ---
$repoRoot = if (Test-Path "AGENTS.md") { (Get-Location).Path } else { $env:REPO_ROOT }
if (-not $repoRoot) { $repoRoot = Resolve-Path "$PSScriptRoot/../.." }
Set-Location $repoRoot

# --- Parse goals file ---
$goalsContent = Get-Content $GoalsFile -Raw

# Extract configuration hook values
$config = @{}
$configLines = $goalsContent | Select-String '(?<=\| `\$)\w+(?=` \| `)(.*?)(?=` \|)' -AllMatches
# Simpler: extract hook=value pairs from Configuration table rows
$configMatches = [regex]::Matches($goalsContent, '\|\s*`\$(\w+)`\s*\|\s*`([^`]+)`')
foreach ($m in $configMatches) {
    $val = $m.Groups[2].Value
    # Strip surrounding double-quotes if present (e.g. "command" -> command)
    if ($val.Length -ge 2 -and $val[0] -eq '"' -and $val[-1] -eq '"') { $val = $val.Substring(1, $val.Length - 2) }
    $config[$m.Groups[1].Value] = $val
}

$logPrefix = if ($config.ContainsKey('LOG_PREFIX')) { $config['LOG_PREFIX'] } else { "runfix-generic" }
$mode = if ($config.ContainsKey('MODE')) { $config['MODE'] } else { "script" }
$targetScript = $config['TARGET_SCRIPT']
if (-not $targetScript) {
    throw "RunFix goals file $GoalsFile is missing required TARGET_SCRIPT configuration"
}
$runCommand = if ($config.ContainsKey('RUN_COMMAND')) { $config['RUN_COMMAND'] } else { $null }
$checkpointResume = $config.ContainsKey('CHECKPOINT_RESUME') -and $config['CHECKPOINT_RESUME'] -eq 'true'
$defaultFlags = if ($config.ContainsKey('FLAGS')) { $config['FLAGS'] } else { "" }
$script:runfixExecutor = if ($defaultFlags -match '-Executor\s+(\S+)') { $Matches[1] } else { $null }

# Allow per-goals-file timeout override (env var still takes precedence)
if ($config.ContainsKey('TIMEOUT_SECONDS') -and -not $env:RUNFIX_TIMEOUT_SECONDS) {
    $runfixTimeoutSec = [int]$config['TIMEOUT_SECONDS']
}

# Parse rubrics
$rubricSuccessPatterns = @()
$rubricFailurePatterns = @()
$rubricExitCode = $true  # default: check exit code
$rubricSection = [regex]::Match($goalsContent, '## Rubrics[^#]*?\n(.*?)(?=\n## |\z)', 'Singleline')
if ($rubricSection.Success) {
    $rubricLines = $rubricSection.Value
    foreach ($line in ($rubricLines -split "`n")) {
        if ($line -match '\|\s*Exit code\s*\|\s*`?\$LASTEXITCODE\s*-eq\s*0') {
            $rubricExitCode = $true
        }
        if ($line -match '\|.*?\|\s*Log contains\s+`([^`]+)`') {
            $rubricSuccessPatterns += $matches[1]
        }
        if ($line -match '\|.*?\|\s*Log does not contain\s+`([^`]+)`') {
            $rubricFailurePatterns += $matches[1]
        }
    }
}

# Parse error table
$errorTable = @()
$errorSection = [regex]::Match($goalsContent, '## [^#]*?Error Table[^#]*?\n(.*?)(?=\n## |\z)', 'Singleline')
if ($errorSection.Success) {
    $errorRows = $errorSection.Value -split "`n"
    $inBody = $false
    foreach ($line in $errorRows) {
        if ($line -match '^\|\s*\d+\s*\|') {
            $inBody = $true
            $parts = $line -split '\|' | ForEach-Object { $_.Trim() }
            if ($parts.Count -ge 4) {
                $errorTable += @{
                    Number = $parts[1]
                    Symptom = $parts[2]
                    Cause   = $parts[3]
                    Fix     = if ($parts.Count -gt 4) { $parts[4] } else { "" }
                }
            }
        }
    }
}

$logDir = "Tasks/Logs"
$null = New-Item -ItemType Directory -Path $logDir -Force
$logPath = Join-Path $logDir "${logPrefix}-${timestamp}-pid${pid}.log"

# --- Recursive process tree killer ---
function Stop-ProcessTree {
    param([int]$ProcessId)
    try {
        $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-ProcessTree -ProcessId $child.ProcessId
            Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        taskkill /F /PID $ProcessId 2>&1 | Out-Null
    } catch {}
    Start-Sleep -Milliseconds 50
}

function Write-RunFixLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [RunFix] $Message"
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Host $line
}

# --- Phase 1: Run target ---
function Invoke-Target {
    param([int]$Cycle)
    Write-RunFixLog "CYCLE $Cycle START: $targetScript"

    $outFile = Join-Path $logDir "${logPrefix}-${timestamp}-pid${pid}-cycle${Cycle}-output.log"
    $errFile = $outFile + ".err"

    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = "pwsh.exe" }

    if ($mode -eq "command" -and $runCommand) {
        $sb = [ScriptBlock]::Create($runCommand)
        $sbSource = $sb.ToString()
        $wrapperCmd = "& { $sbSource 2>&1 | Out-String } 6>&1"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($wrapperCmd)
        $encoded = [Convert]::ToBase64String($bytes)
        $stdinFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -NoNewWindow -FilePath $pwshExe -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) -PassThru -RedirectStandardInput $stdinFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $proc.WaitForExit($runfixTimeoutSec * 1000) | Out-Null
        if (-not $proc.HasExited) {
            Stop-ProcessTree -ProcessId $proc.Id
            Write-RunFixLog "CYCLE $Cycle TIMEOUT: process tree killed after ${runfixTimeoutSec}s"
            return @{ Output = "TIMEOUT"; ExitCode = -1; OutFile = $outFile }
        }
        $exitCode = $proc.ExitCode
        Remove-Item -LiteralPath $stdinFile -ErrorAction SilentlyContinue
    } else {
        $flags = if ($defaultFlags) { @($defaultFlags) } else { @() }
        $flags += $ExtraArgs
        $flagStr = if ($flags.Count -gt 0) { " " + ($flags -join ' ') } else { "" }
        $cmdLine = "& '$targetScript'$flagStr 6>&1"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmdLine)
        $encoded = [Convert]::ToBase64String($bytes)
        $stdinFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -NoNewWindow -FilePath $pwshExe -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) -PassThru -RedirectStandardInput $stdinFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $proc.WaitForExit($runfixTimeoutSec * 1000) | Out-Null
        if (-not $proc.HasExited) {
            Stop-ProcessTree -ProcessId $proc.Id
            Write-RunFixLog "CYCLE $Cycle TIMEOUT: process tree killed after ${runfixTimeoutSec}s"
            return @{ Output = "TIMEOUT"; ExitCode = -1; OutFile = $outFile }
        }
        $exitCode = $proc.ExitCode
        Remove-Item -LiteralPath $stdinFile -ErrorAction SilentlyContinue
    }

    $output = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    $outputText = ($output, $stderr) | Where-Object { $_ } | Out-String
    Write-RunFixLog "CYCLE $Cycle END: exit code $exitCode"
    return @{ Output = $outputText; ExitCode = $exitCode; OutFile = $outFile }
}

# --- Phase 1b: Launch target in background (non-blocking) ---
function Start-TargetBackground {
    param([int]$Cycle)

    $outFile = Join-Path $logDir "${logPrefix}-${timestamp}-pid${pid}-cycle${Cycle}-output.log"
    $errFile = $outFile + ".err"

    Write-RunFixLog "CYCLE $Cycle LAUNCH: $targetScript"

    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) { $pwshExe = "pwsh.exe" }

    # Build env var init fragment — Start-Process with -RedirectStandard* does NOT
    # inherit the parent's env vars. Explicitly pass critical ones through the cmd.
    $envInit = ""
    foreach ($envVar in @('AWS_SSO_PROFILE', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_DEFAULT_REGION')) {
        $val = [Environment]::GetEnvironmentVariable($envVar, 'Process')
        if ($val) {
            $escaped = $val -replace "'", "''"
            $envInit += "`$env:$envVar = '$escaped'; "
        }
    }

    if ($mode -eq "command" -and $runCommand) {
        $sb = [ScriptBlock]::Create($runCommand)
        $wrapperCmd = "${envInit}& { $($sb.ToString()) 2>&1 | Out-String } 6>&1"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($wrapperCmd)
        $encoded = [Convert]::ToBase64String($bytes)
        $stdinFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -NoNewWindow -FilePath $pwshExe `
            -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
            -PassThru -RedirectStandardInput $stdinFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } else {
        $flags = if ($defaultFlags) { @($defaultFlags) } else { @() }
        $flags += $ExtraArgs
        $flagStr = if ($flags.Count -gt 0) { " " + ($flags -join ' ') } else { "" }
        $cmdLine = "${envInit}& '$targetScript'$flagStr 6>&1"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmdLine)
        $encoded = [Convert]::ToBase64String($bytes)
        $stdinFile = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -NoNewWindow -FilePath $pwshExe `
            -ArgumentList @("-NoProfile", "-EncodedCommand", $encoded) `
            -PassThru -RedirectStandardInput $stdinFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    }

    return @{
        Process   = $proc
        OutFile   = $outFile
        ErrFile   = $errFile
        StdinFile = $stdinFile
    }
}

# --- Phase 1c: Commit and push fixes ---
function Invoke-FixCommitAndPush {
    param([int]$Cycle)

    try {
        $dirty = git status --porcelain 2>&1 | Out-String
        if (-not $dirty.Trim()) {
            Write-RunFixLog "CYCLE ${Cycle}: COMMIT — no changes to commit"
            return
        }

        git add -A 2>&1 | Out-Null
        git commit -m "RunFix cycle ${Cycle}: auto-fix applied" 2>&1 | Out-Null
        & (Resolve-Path "$repoRoot/Skills/DevOps/Git/Invoke-GitPullSafe.ps1") 2>&1 | Out-Null
        git push 2>&1 | Out-Null
        Write-RunFixLog "CYCLE ${Cycle}: COMMIT — changes committed and pushed"
    } catch {
        Write-RunFixLog "CYCLE ${Cycle}: COMMIT — failed: $_"
    }
}

# --- Phase 1.5: Check rubrics ---
function Test-Rubrics {
    param([string]$OutputText, [int]$ExitCode)
    $fatalFailures = @()
    $waitingFailures = @()

    if ($rubricExitCode -and $ExitCode -ne 0) {
        $fatalFailures += "Exit code $ExitCode (expected 0)"
    }

    foreach ($pattern in $rubricSuccessPatterns) {
        if ($OutputText -notmatch $pattern) {
            $waitingFailures += "Output missing success pattern: $pattern"
        }
    }

    foreach ($pattern in $rubricFailurePatterns) {
        if ($OutputText -match $pattern) {
            $fatalFailures += "Output contains failure pattern: $pattern"
        }
    }

    return @{
        Passed          = ($fatalFailures.Count -eq 0 -and $waitingFailures.Count -eq 0)
        Failures        = $fatalFailures + $waitingFailures
        FatalFailures   = $fatalFailures
        WaitingFailures = $waitingFailures
    }
}

# --- Context-gated exit to prevent infinite identical-failure loops ---
function Test-ContextGate {
    param([array]$Failures, [int]$Cycle)
    $failureKey = ($Failures | Sort-Object) -join '|'
    if ($failureKey -eq $script:previousFailureKey) {
        $script:consecutiveIdenticalFailures++
    } else {
        $script:consecutiveIdenticalFailures = 1
    }
    $script:previousFailureKey = $failureKey
    if ($script:consecutiveIdenticalFailures -ge 4) {
        $handoffDir = Join-Path $repoRoot "Tasks" "Handoff"
        $null = New-Item -ItemType Directory -Path $handoffDir -Force
        $handoffPath = Join-Path $handoffDir "runfix-context-gate-${timestamp}-pid${pid}.json"
        @{
            status = 'context-gated'
            cycle = $Cycle
            timestamp = (Get-Date -Format 'o')
            failureKey = $failureKey
            failures = $Failures
        } | ConvertTo-Json -Depth 5 | Set-Content $handoffPath -Encoding UTF8
        Write-RunFixLog "CONTEXT_GATE: consecutive identical failures reached threshold — handoff written to $handoffPath"
        exit 99
    }
}

# --- Phase 2: Diagnose + fix via model ---
function Invoke-DiagnoseAndFix {
    param([string]$OutputText, [int]$ExitCode, [int]$Cycle)

    $crashEvidence = @()
    if ($OutputText -match 'CRASH_EVIDENCE:\s*(\S+)') {
        $evidencePaths = $Matches[1] -split ',' | ForEach-Object { $_.Trim() }
        foreach ($ep in $evidencePaths) {
            $resolved = if ([System.IO.Path]::IsPathRooted($ep)) { $ep } else { Join-Path (Get-Location) $ep }
            if (Test-Path $resolved) {
                $crashEvidence += @{ path = $ep; content = Get-Content $resolved -Raw -ErrorAction SilentlyContinue }
                Write-RunFixLog "CRASH_EVIDENCE: read $ep"
            } else {
                Write-RunFixLog "CRASH_EVIDENCE: path not found — $ep"
            }
        }
    }

    # Write context file for the model
    $context = @{
        script = $targetScript
        mode   = $mode
        exit_code = $ExitCode
        output = $OutputText
        errors = $errorTable
        log    = $logPath
    }
    if ($crashEvidence.Count -gt 0) { $context.crash_evidence = $crashEvidence }
    $contextJson = $context | ConvertTo-Json -Depth 10

    $contextFile = Join-Path $logDir "${logPrefix}-${timestamp}-pid${pid}-cycle${Cycle}-context.json"
    $contextJson | Set-Content $contextFile -Encoding UTF8

    Write-RunFixLog "CYCLE $Cycle DIAGNOSE: writing context to $contextFile"

    # Call opencode run --command fix-diagnose with context file path
    $diagnoseOut = Join-Path $logDir "${logPrefix}-${timestamp}-pid${pid}-cycle${Cycle}-diagnose.log"
    $proc = Start-Process -NoNewWindow -FilePath $ocExe `
        -ArgumentList @('run', '--command', 'fix-diagnose', '--', $contextFile) `
        -PassThru -RedirectStandardOutput $diagnoseOut -RedirectStandardError ($diagnoseOut + ".err")
    $diagnoseStart = Get-Date
    $diagnoseTimeout = 120  # 2 minutes max for diagnosis
    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 5
        if (((Get-Date) - $diagnoseStart).TotalSeconds -ge $diagnoseTimeout) {
            Stop-ProcessTree -ProcessId $proc.Id
            Write-RunFixLog "CYCLE $Cycle DIAGNOSE TIMEOUT: killed after ${diagnoseTimeout}s"
            break
        }
    }
    $proc.WaitForExit()

    if ($proc.ExitCode -eq 0) {
        Write-RunFixLog "CYCLE $Cycle DIAGNOSE: fix applied (exit 0)"
        return $true
    }

    Write-RunFixLog "CYCLE $Cycle DIAGNOSE: failed (exit $($proc.ExitCode))"

    # On diagnosis failure with crash evidence, write a session plan to Tasks/Code/
    if ($crashEvidence.Count -gt 0) {
        $planDate = Get-Date -Format 'yyyy.MM.dd'
        $planName = "${planDate}-runfix-crash-recovery.md"
        $planPath = Join-Path (Get-Location) "Tasks/Code" $planName
        $planContent = @"
# Session Plan: $planDate — RunFix crash recovery

**Status**: ready
**Date**: $planDate
**Script**: $targetScript
**Cycle**: $Cycle

## Problem
Diagnosis failed with crash evidence present. The script exited with code $ExitCode.

## Evidence
$($crashEvidence | ForEach-Object { "- $($_.path)" } | Out-String)

## Tasks
1. Investigate the crash evidence above and diagnose root cause
2. Apply the fix to $targetScript
3. Re-run RunFix: `.\Skills\\Orchestration\RunFix.ps1 -Script $targetScript`

## Verification
- RunFix should recover and complete all cycles
- No further crash evidence should appear
"@
        $planContent | Set-Content $planPath -Encoding UTF8
        Write-RunFixLog "CRASH_EVIDENCE: session plan written to $planPath"
    }

    return $false
}

# --- Terminal error detection ---
function Test-TerminalConditions {
    $failures = @()
    $skipTerminal = $env:RUNFIX_SKIP_TERMINAL_CHECKS -eq '1'
    if ($skipTerminal) {
        Write-RunFixLog "TERMINAL_CHECKS: skipped (RUNFIX_SKIP_TERMINAL_CHECKS=1)"
        return @()
    }

    $executorNeedsAws = $true
    if ($script:runfixExecutor -eq 'local') { $executorNeedsAws = $false }

    if ($executorNeedsAws) {
        # AWS SSO
        $ssoProfile = if ($env:AWS_SSO_PROFILE) { $env:AWS_SSO_PROFILE } else { "interclaw" }
        try {
            $ssoResult = aws sts get-caller-identity --profile $ssoProfile 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-RunFixLog "AWS_SSO: session expired for $ssoProfile — attempting device-code re-auth"
                aws sso login --profile $ssoProfile --use-device-code 2>&1 | Out-Null
                Start-Sleep -Seconds 3
                $ssoResult = aws sts get-caller-identity --profile $ssoProfile 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $failures += "AWS_SSO: session expired and device-code re-auth failed for $ssoProfile"
                } else {
                    Write-RunFixLog "AWS_SSO: device-code re-auth succeeded"
                }
            }
        } catch {
            $failures += "AWS_SSO: aws CLI not available"
        }

        # Cache SSO credentials as env vars so child processes don't need SSO browser re-auth.
        # Also set AWS_SSO_PROFILE so Invoke-AwsCommand writes creds to the correct section.
        if ($failures.Count -eq 0) {
            $env:AWS_SSO_PROFILE = $ssoProfile
            try {
                $creds = aws configure export-credentials --profile $ssoProfile --format env 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0 -and $creds -match 'AWS_ACCESS_KEY_ID') {
                    $env:AWS_ACCESS_KEY_ID = if ($creds -match 'AWS_ACCESS_KEY_ID=(\S+)') { $Matches[1] }
                    $env:AWS_SECRET_ACCESS_KEY = if ($creds -match 'AWS_SECRET_ACCESS_KEY=(\S+)') { $Matches[1] }
                    $env:AWS_SESSION_TOKEN = if ($creds -match 'AWS_SESSION_TOKEN=(\S+)') { $Matches[1] }
                    # Read default region from the SSO profile config, fall back to ca-central-1
                    $regionResult = aws configure get region --profile $ssoProfile 2>&1
                    if ($LASTEXITCODE -eq 0 -and $regionResult -match '\S') {
                        $env:AWS_DEFAULT_REGION = $regionResult.Trim()
                    } else {
                        $env:AWS_DEFAULT_REGION = "ca-central-1"
                    }
                    Write-RunFixLog "AWS_CREDS: cached temporary credentials for $ssoProfile (expire ~1hr, region=$env:AWS_DEFAULT_REGION)"
                } else {
                    Write-RunFixLog "AWS_CREDS: export-credentials failed for $ssoProfile (profile may use env vars already)"
                }
            } catch {
                Write-RunFixLog "AWS_CREDS: exception caching credentials: $_"
            }
        }

        # Docker
        try {
            $null = docker info 2>&1
            if ($LASTEXITCODE -ne 0) {
                $failures += "DOCKER: docker info failed"
            }
        } catch {
            $failures += "DOCKER: docker CLI not available"
        }
    } else {
        Write-RunFixLog "TERMINAL_CHECKS: AWS SSO and Docker checks skipped (executor=$script:runfixExecutor)"
    }

    # Disk space
    try {
        $lowSpace = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Free -lt 1GB -and $_.Used -gt 0 }
        if ($lowSpace) {
            $lowDrive = $lowSpace | Select-Object -First 1
            $failures += "DISK: $($lowDrive.Name) has less than 1GB free ($([math]::Round($lowDrive.Free/1GB,2))GB)"
        }
    } catch {
        Write-RunFixLog "TERMINAL_DISK_CHECK_FAILED error='$($_.Exception.Message)'"
    }

    # Network
    try {
        $netResult = Test-NetConnection -ComputerName 8.8.8.8 -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet 2>&1
        if (-not $netResult) {
            $failures += "NETWORK: cannot reach 8.8.8.8:443"
        }
    } catch {
        $failures += "NETWORK: connectivity check failed"
    }

    return $failures
}

# --- Main loop ---
Write-RunFixLog "=== RUNFIX START ==="
Write-RunFixLog "GoalsFile: $GoalsFile"
Write-RunFixLog "Target: $targetScript"
Write-RunFixLog "Mode: $mode"
Write-RunFixLog "PollInterval: ${PollIntervalSeconds}s | MaxWall: ${runfixMaxWallMinutes}m"

if ($mode -eq "command") {
    # Command mode: RUN_COMMAND is required instead of TARGET_SCRIPT
    if ([string]::IsNullOrEmpty($runCommand)) {
        Write-RunFixLog "FATAL: Mode 'command' but no RUN_COMMAND defined in goals file"
        exit 1
    }
    Write-RunFixLog "Command: $runCommand"
} else {
    # Script mode: TARGET_SCRIPT is required
    if ([string]::IsNullOrEmpty($targetScript)) {
        Write-RunFixLog "FATAL: No TARGET_SCRIPT defined in goals file"
        exit 1
    }
    if (-not (Test-Path $targetScript)) {
        Write-RunFixLog "FATAL: Target script not found at $targetScript"
        exit 1
    }
}

# Preflight: verify opencode CLI is available for diagnosis
$ocExe = (Get-Command 'opencode.cmd' -ErrorAction SilentlyContinue).Source
if (-not $ocExe) { $ocExe = (Get-Command 'opencode' -ErrorAction SilentlyContinue).Source }
if (-not $ocExe) {
    Write-RunFixLog "FATAL: opencode CLI not found — required for fix-diagnose"
    exit 1
}
Write-RunFixLog "opencode CLI found: $ocExe"

# --- Orphan cleanup: kill only subprocesses spawned by THIS RunFix process ---
$stalePids = @()
try {
    $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$PID" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        if ($child.Name -match 'opencode|pwsh|powershell') {
            $stalePids += $child.ProcessId
        }
    }
} catch {}
$stalePids = $stalePids | Select-Object -Unique
if ($stalePids.Count -gt 0) {
    Write-RunFixLog "ORPHAN_CLEANUP: found $($stalePids.Count) stale subprocess(es) directly under RunFix PID $PID — PID(s): $($stalePids -join ', ')"
    foreach ($stalePid in $stalePids) {
        Stop-ProcessTree -ProcessId $stalePid
    }
    Write-RunFixLog "ORPHAN_CLEANUP: performed"
} else {
    Write-RunFixLog "ORPHAN_CLEANUP: no stale subprocesses found directly under RunFix PID $PID"
}

# ─── Polling loop: 1-min interval, up to wall-time limit ─────────────
$deadline = (Get-Date).AddMinutes($runfixMaxWallMinutes)
$pollIntervalMs = $PollIntervalSeconds * 1000
$cycleCount = 0
$proc = $null
$currentOutFile = ""
$currentErrFile = ""
$currentStdinFile = ""
$fixesApplied = @()
$script:previousLogErrors = $null
$script:consecutiveIdenticalFailures = 1
$script:previousFailureKey = $null

while ((Get-Date) -lt $deadline) {
    Write-RunFixLog "TICK: Starting poll cycle (wall ${runfixMaxWallMinutes}m, started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"

    # ── Terminal condition check at each poll ──
    $terminalFailures = Test-TerminalConditions
    if ($terminalFailures.Count -gt 0) {
        foreach ($tf in $terminalFailures) {
            Write-RunFixLog "TERMINAL: $tf"
        }
        Write-RunFixLog "=== RUNFIX FAILED (terminal condition) ==="
        exit 1
    }

    # ── Preflight: target script must exist ──
    if ($mode -eq "script" -and $targetScript -and -not (Test-Path $targetScript)) {
        Write-RunFixLog "PREFLIGHT FAILED — target script not found: $targetScript"
        Write-RunFixLog "=== RUNFIX FAILED (preflight: missing target) ==="
        exit 1
    }

    # Re-read goals file config for values LLM may have updated — each poll cycle
    $goalsContent = Get-Content $GoalsFile -Raw
    $config = @{}
    $configMatches = [regex]::Matches($goalsContent, '\|\s*`\$(\w+)`\s*\|\s*`([^`]+)`')
    foreach ($m in $configMatches) {
        $config[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    $defaultFlags = if ($config.ContainsKey('FLAGS')) { $config['FLAGS'] } else { "" }
    $script:runfixExecutor = if ($defaultFlags -match '-Executor\s+(\S+)') { $Matches[1] } else { $null }
    if ($config.ContainsKey('TIMEOUT_SECONDS') -and -not $env:RUNFIX_TIMEOUT_SECONDS) {
        $runfixTimeoutSec = [int]$config['TIMEOUT_SECONDS']
    }
    $rubricSuccessPatterns = @()
    $rubricFailurePatterns = @()
    $rubricExitCode = $true
    $rubricSection = [regex]::Match($goalsContent, '## Rubrics[^#]*?\n(.*?)(?=\n## |\z)', 'Singleline')
    if ($rubricSection.Success) {
        $rubricLines = $rubricSection.Value
        foreach ($line in ($rubricLines -split "`n")) {
            if ($line -match '\|\s*Exit code\s*\|\s*`?\$LASTEXITCODE\s*-eq\s*0') {
                $rubricExitCode = $true
            }
            if ($line -match '\|.*?\|\s*(?:Log|Output)\s+contains\s+`([^`]+)`') {
                $rubricSuccessPatterns += $Matches[1]
            }
            if ($line -match '\|.*?\|\s*(?:Log|Output)\s+does not contain\s+`([^`]+)`') {
                $rubricFailurePatterns += $Matches[1]
            }
        }
    }
    $errorTable = @()
    $errorSection = [regex]::Match($goalsContent, '## [^#]*?Error Table[^#]*?\n(.*?)(?=\n## |\z)', 'Singleline')
    if ($errorSection.Success) {
        $errorRows = $errorSection.Value -split "`n"
        foreach ($line in $errorRows) {
            if ($line -match '^\|\s*\d+\s*\|') {
                $parts = $line -split '\|' | ForEach-Object { $_.Trim() }
                if ($parts.Count -ge 4) {
                    $errorTable += @{
                        Number = $parts[1]
                        Symptom = $parts[2]
                        Cause   = $parts[3]
                        Fix     = if ($parts.Count -gt 4) { $parts[4] } else { "" }
                    }
                }
            }
        }
    }

    # ── Launch if no process running ──
    if ($null -eq $proc -or $proc.HasExited) {
        if ($null -ne $proc -and $proc.HasExited) {
            Write-RunFixLog "CYCLE ${cycleCount}: process exited with code $($proc.ExitCode)"

            # Read final output
            $finalOutput = Get-Content $currentOutFile -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content $currentErrFile -Raw -ErrorAction SilentlyContinue
            $outputText = ($finalOutput, $stderr) | Where-Object { $_ } | Out-String

            # Check rubrics on completed run
            $rubricResult = Test-Rubrics -OutputText $outputText -ExitCode $proc.ExitCode

            if ($rubricResult.Passed) {
                Write-RunFixLog "ALL RUBRICS PASSED — process completed successfully after $cycleCount cycles"
                Write-RunFixLog "=== RUNFIX COMPLETE (success) ==="
                exit 0
            }

            Write-RunFixLog "CYCLE ${cycleCount}: Process completed with rubric failures: $($rubricResult.Failures -join '; ')"

            # Clean up stdin file from previous run
            if ($currentStdinFile -and (Test-Path $currentStdinFile)) {
                Remove-Item -LiteralPath $currentStdinFile -Force -ErrorAction SilentlyContinue
            }

            # If fatal failures, diagnose and fix before re-launch
            if ($rubricResult.FatalFailures.Count -gt 0) {
                Test-ContextGate -Failures $rubricResult.FatalFailures -Cycle $cycleCount
                Write-RunFixLog "CYCLE ${cycleCount}: Fatal failures — diagnosing and fixing"

                # Check error table first
                $tableFixApplied = $false
                foreach ($row in $errorTable) {
                    if ($outputText -match $row.Symptom) {
                        Write-RunFixLog "CYCLE ${cycleCount}: ERROR TABLE MATCH row=$($row.Number) — applying documented fix"
                        if ($row.Fix) {
                            try {
                                $fixSb = [ScriptBlock]::Create($row.Fix)
                                & $fixSb
                                $tableFixApplied = $true
                                Write-RunFixLog "CYCLE ${cycleCount}: TABLE FIX applied row=$($row.Number)"
                            } catch {
                                Write-RunFixLog "CYCLE ${cycleCount}: TABLE FIX FAILED row=$($row.Number): $($_.Exception.Message)"
                            }
                        }
                        break
                    }
                }

                if (-not $tableFixApplied) {
                    $fixed = Invoke-DiagnoseAndFix -OutputText $outputText -ExitCode $proc.ExitCode -Cycle $cycleCount
                    if (-not $fixed) {
                        Write-RunFixLog "=== RUNFIX FAILED (diagnosis failed at cycle $cycleCount) ==="
                        exit 1
                    }
                }

                # Commit and push the fix
                Invoke-FixCommitAndPush -Cycle $cycleCount
                $fixesApplied += $cycleCount
                Write-RunFixLog "CYCLE ${cycleCount}: Fix committed and pushed, re-launching..."
            } else {
                # Only waiting failures — just re-launch
                Write-RunFixLog "CYCLE ${cycleCount}: Waiting — re-launching target"
            }
        }

        # Launch new background process
        $cycleCount++
        $launchInfo = Start-TargetBackground -Cycle $cycleCount
        $proc = $launchInfo.Process
        $currentOutFile = $launchInfo.OutFile
        $currentErrFile = $launchInfo.ErrFile
        $currentStdinFile = $launchInfo.StdinFile
        Write-RunFixLog "CYCLE ${cycleCount}: process launched, PID $($proc.Id)"

        continue
    }

    # ── Poll: wait interval then check running process ──
    Start-Sleep -Milliseconds $pollIntervalMs

    # ── Per-cycle timeout check ──
    if (-not $proc.HasExited) {
        $elapsed = [math]::Round(((Get-Date) - $proc.StartTime).TotalSeconds, 0)
        if ($elapsed -ge $runfixTimeoutSec) {
            Write-RunFixLog "POLL ${cycleCount}: Process exceeded ${runfixTimeoutSec}s timeout ($elapsed s elapsed) — killing"
            Stop-ProcessTree -ProcessId $proc.Id
            if ($currentStdinFile -and (Test-Path $currentStdinFile)) {
                Remove-Item -LiteralPath $currentStdinFile -Force -ErrorAction SilentlyContinue
            }
            continue
        }
    }

    if ($proc.HasExited) {
        continue
    }

    # ── Read partial output and check rubrics ──
    $currentOutput = Get-Content $currentOutFile -Raw -ErrorAction SilentlyContinue
    $currentStderr = Get-Content $currentErrFile -Raw -ErrorAction SilentlyContinue
    $outputText = ($currentOutput, $currentStderr) | Where-Object { $_ } | Out-String

    # Check rubrics on partial output (no exit code yet)
    $rubricResult = Test-Rubrics -OutputText $outputText -ExitCode $null

    # Also check log files for errors
    $logCheckGlob = if ($config.ContainsKey('LOG_CHECK_GLOB')) { $config['LOG_CHECK_GLOB'] } else { $null }
    if ($logCheckGlob) {
        $logErrors = @()
        $logFiles = Get-ChildItem (Join-Path $repoRoot $logCheckGlob) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
        foreach ($lf in $logFiles) {
            Get-Content $lf.FullName -Tail 50 -ErrorAction SilentlyContinue | ForEach-Object {
                try { $je = $_ | ConvertFrom-Json -ErrorAction SilentlyContinue } catch { return }
                if ($null -eq $je.level -or ($je.level -ne 'ERROR' -and $je.level -ne 'WARN')) { return }
                if ($je.message -match 'STALE_INVESTIGATION|STALE_PLAN_SKIPPED|STALE_PLAN_CREATED|WORKTREE_CLEANUP_COMPLETE|RETRY_BUDGET_GC_SKIP|STATE_DISCREPANCY|STATE_RECONCILE|FILESYSTEM_STATE|SENTINEL_SKIP_MISSING_DIR') { return }
                $logErrors += "${lf.Name}:$($je.message)"
            }
        }
        if ($logErrors.Count -gt 0) {
            Write-RunFixLog "POLL ${cycleCount}: LOG_ERRORS found — $($logErrors -join '; ')"
            $logErrorKey = $logErrors -join '|'
            if ($script:previousLogErrors -and $logErrorKey -eq $script:previousLogErrors) {
                $rubricResult.FatalFailures += "Orchestrator log contains errors: $($logErrors[0])"
                $rubricResult.Failures = $rubricResult.FatalFailures + $rubricResult.WaitingFailures
            }
            $script:previousLogErrors = $logErrorKey
        } else {
            $script:previousLogErrors = $null
        }
    }

    if ($rubricResult.Passed) {
        Write-RunFixLog "POLL ${cycleCount}: ALL RUBRICS PASSED (while running)"
        Write-RunFixLog "=== RUNFIX COMPLETE (success during cycle $cycleCount) ==="
        exit 0
    }

    if ($rubricResult.FatalFailures.Count -gt 0) {
        Test-ContextGate -Failures $rubricResult.FatalFailures -Cycle $cycleCount
        Write-RunFixLog "POLL ${cycleCount}: Fatal failures detected live: $($rubricResult.FatalFailures -join '; ')"

        # Kill current process
        Stop-ProcessTree -ProcessId $proc.Id
        if ($currentStdinFile -and (Test-Path $currentStdinFile)) {
            Remove-Item -LiteralPath $currentStdinFile -Force -ErrorAction SilentlyContinue
        }

        # Read full output for diagnosis
        $fullOutput = Get-Content $currentOutFile -Raw -ErrorAction SilentlyContinue
        $fullStderr = Get-Content $currentErrFile -Raw -ErrorAction SilentlyContinue
        $diagnosisOutput = ($fullOutput, $fullStderr) | Where-Object { $_ } | Out-String

        # Check error table first
        $tableFixApplied = $false
        foreach ($row in $errorTable) {
            if ($diagnosisOutput -match $row.Symptom) {
                Write-RunFixLog "CYCLE ${cycleCount}: ERROR TABLE MATCH row=$($row.Number) — applying documented fix"
                if ($row.Fix) {
                    try {
                        $fixSb = [ScriptBlock]::Create($row.Fix)
                        & $fixSb
                        $tableFixApplied = $true
                        Write-RunFixLog "CYCLE ${cycleCount}: TABLE FIX applied row=$($row.Number)"
                    } catch {
                        Write-RunFixLog "CYCLE ${cycleCount}: TABLE FIX FAILED row=$($row.Number): $($_.Exception.Message)"
                    }
                }
                break
            }
        }

        if (-not $tableFixApplied) {
            $fixed = Invoke-DiagnoseAndFix -OutputText $diagnosisOutput -ExitCode -1 -Cycle $cycleCount
            if (-not $fixed) {
                Write-RunFixLog "=== RUNFIX FAILED (diagnosis failed at cycle $cycleCount) ==="
                exit 1
            }
        }

        # Commit and push the fix
        Invoke-FixCommitAndPush -Cycle $cycleCount
        $fixesApplied += $cycleCount
        Write-RunFixLog "CYCLE ${cycleCount}: Fix committed and pushed, re-launching..."
        continue
    }

    # Only waiting failures: success patterns not yet met — keep polling
    $wallRemaining = [math]::Round(($deadline - (Get-Date)).TotalMinutes, 0)
    Write-RunFixLog "POLL ${cycleCount}: Waiting — success patterns not yet met (${wallRemaining}m wall time remaining)"
}

Write-RunFixLog "=== RUNFIX FAILED (wall time ${runfixMaxWallMinutes}m exceeded after $cycleCount cycles) ==="
exit 1
