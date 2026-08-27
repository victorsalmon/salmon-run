<#
.SYNOPSIS
    Orchestrator sandbox for testing dispatch, crash recovery, DependsOn ordering,
    and parallel namespace behaviour without touching the real repo.
#>

function New-OrchestratorSandbox {
    param([hashtable[]]$Plans)
    $sandboxRoot = Join-Path $env:TEMP "OrchestratorSandbox-$([System.IO.Path]::GetRandomFileName())"
    $null = New-Item -ItemType Directory -Path $sandboxRoot -Force
    foreach ($sub in @("Tasks/Code", "Tasks/Review", "Tasks/Working", "Tasks/Logs/agents", "Tasks/Locks", "Tasks/Schedule")) {
        $null = New-Item -ItemType Directory -Path (Join-Path $sandboxRoot $sub) -Force
    }
    $skillDir = Join-Path $sandboxRoot "Skills/Orchestration"
    $null = New-Item -ItemType Directory -Path $skillDir -Force
    $srcFiles = Get-ChildItem "Skills/Orchestration/*.ps1" -ErrorAction SilentlyContinue
    foreach ($sf in $srcFiles) {
        try { New-Item -ItemType SymbolicLink -Path (Join-Path $skillDir $sf.Name) -Target $sf.FullName -Force -ErrorAction Stop } catch { }
    }
    $configDir = Join-Path $sandboxRoot "Configuration"
    $null = New-Item -ItemType Directory -Path $configDir -Force
    try { New-Item -ItemType SymbolicLink -Path (Join-Path $configDir "Providers") -Target (Resolve-Path "Configuration/Providers") -Force -ErrorAction Stop } catch { }
    foreach ($plan in $Plans) {
        $queueDir = Join-Path $sandboxRoot "Tasks/$($plan.role)"
        $null = New-Item -ItemType Directory -Path $queueDir -Force
        $planContent = @"
**Lock**
- Agent: $($plan.agent)
- Locked: $(Get-Date -Format 'o')
- Status: $($plan.status)

## Tasks
1. **$($plan.name)**

**Namespace**: $($plan.namespace)
**Status**: ready
"@
        $planPath = Join-Path $queueDir "$($plan.name).md"
        Set-Content -Path $planPath -Value $planContent -Encoding utf8 -NoNewline
    }
    return $sandboxRoot
}

function Invoke-SandboxOrchestrator {
    param([string]$SandboxDir)
    $orchPath = Join-Path $SandboxDir "Skills/Orchestration/LocalOrchestrator.ps1"
    if (-not (Test-Path $orchPath)) { return $null }
    $logDir = Join-Path $SandboxDir "Tasks/Logs"
    $null = New-Item -ItemType Directory -Path $logDir -Force
    $proc = Start-Process -FilePath "powershell" -ArgumentList @(
        "-NoProfile", "-NoLogo", "-File", $orchPath,
        "-InterclawDir", $SandboxDir,
        "-SpawnMode", "Subprocess",
        "-CodeParallelCount", "2",
        "-ReviewerParallelCount", "2",
        "-MaxIterations", "10"
    ) -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $logDir "sandbox-stdout.log") -RedirectStandardError (Join-Path $logDir "sandbox-stderr.log")
    return $proc
}

function Test-SandboxOutcome {
    param([string]$SandboxDir, [hashtable]$ExpectedState)
    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($queue in $ExpectedState.Keys) {
        $expectedFiles = $ExpectedState[$queue] | Sort-Object
        $actualFiles = @(Get-ChildItem "$SandboxDir/Tasks/$queue/*.md" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
        foreach ($ef in $expectedFiles) {
            if ($ef -notin $actualFiles) {
                $failures.Add("Expected '$ef' in Tasks/$queue/ but not found")
            }
        }
        foreach ($af in $actualFiles) {
            if ($af -notin $expectedFiles) {
                $failures.Add("Unexpected '$af' in Tasks/$queue/")
            }
        }
    }
    return @{ Passed = $failures.Count -eq 0; Failures = $failures }
}
