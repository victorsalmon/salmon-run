#Requires -Version 7.0
<#
.SYNOPSIS
    OpenCode provider executor for the salmon-run PondEngine.

.DESCRIPTION
    Runs the `opencode` CLI for the `opencode-go` and `opencode` providers.
    It builds `opencode run <prompt> --model {model} --variant {effort}
    --auto -f {plan1} -f {plan2} ...` and captures the result.

    The adapter appends `spawn`, `external-complete`, and `external-fail`
    events to each plan's **PondLog**, and writes a `.complete` sentinel on
    success or a `.failed` sentinel on any non-zero outcome.

    Credentials:
    - If `OPENCODE_GO_KEY` is set (via SalmonRun.Credentials or the process
      environment), it is exported for the CLI.
    - If it is not set, the executor still runs; the `opencode` CLI will use
      its own provider configuration or any free-tier model that does not
      require a key.

    Exit code 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('coder','reviewer','auditor','qa','planner','project','project-planner','project-reviewer','investigator')]
    [string]$Role,

    [Parameter(Mandatory)]
    [string]$LanePath,

    [Parameter(Mandatory)]
    [string]$RepoDir,

    [ValidateSet('opencode','opencode-go')]
    [string]$Provider = 'opencode',

    [string]$Model,

    [string]$Effort,

    [int]$TimeoutMinutes = 30,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PondVerdict.ps1')
. (Join-Path $PSScriptRoot 'RolePrompts.ps1')

$script:SupportedProviders = @('opencode','opencode-go')
$script:SupportedModels = @{
    'opencode'     = @('opencode/hy3-free','opencode/mimo-v2.5-free')
    'opencode-go'  = @('opencode-go/hy3','opencode-go/mimo-v2.5','opencode-go/deepseek-v4-flash','opencode-go/deepseek-v4-pro')
}

function Resolve-OpencodeCredential {
    <#
    .SYNOPSIS
        Resolves OPENCODE_GO_KEY from SalmonRun.Credentials when available,
        otherwise from the process environment. Returns null if not found.
    #>
    $key = $null
    if (Get-Command Get-SalmonRunCredential -ErrorAction SilentlyContinue) {
        try {
            $key = Get-SalmonRunCredential -Name 'OPENCODE_GO_KEY'
        } catch {
            $key = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = $env:OPENCODE_GO_KEY
    }
    return $key
}

function Resolve-OpencodeWindowsToolPath {
    <#
    .SYNOPSIS
        Returns the path entries that should be prepended to the child process
        PATH so POSIX shell commands (head, grep, find, cat, etc.) resolve on
        Windows. Returns null on non-Windows or when Git for Windows is not found.
    #>
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    if (-not $onWindows) { return $null }

    $candidates = @()

    # Derive the POSIX tool directory from the installed `git` command.
    $gitCommand = Get-Command 'git' -ErrorAction SilentlyContinue
    if ($gitCommand) {
        $gitRoot = (Get-Item (Join-Path $gitCommand.Source '..' '..')).FullName
        if ($gitRoot) {
            $candidates += Join-Path $gitRoot 'usr\bin'
            $candidates += Join-Path $gitRoot 'bin'
        }
    }

    # Common install locations as fallbacks.
    foreach ($base in @('C:\Program Files\Git', 'C:\Program Files (x86)\Git')) {
        $candidates += Join-Path $base 'usr\bin'
        $candidates += Join-Path $base 'bin'
    }

    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
    if ($found.Count -eq 0) { return $null }

    return ($found -join [System.IO.Path]::PathSeparator)
}

function Get-OpencodeRolePrompt {
    <#
    .SYNOPSIS
        Returns the shared Salmon Run role prompt for the OpenCode provider.
    #>
    param(
        [string]$Role,
        [string]$RepoDir
    )

    return Get-RolePrompt -Role $Role -RepoDir $RepoDir -Provider $Provider -Model $Model
}

function Write-PlanLog {
    <#
    .SYNOPSIS
        Appends a single PondLog event to every plan the executor processed.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Detail,

        [string]$Agent = "opencode-$Provider"
    )

    if (-not (Get-Command Add-PlanPondLog -ErrorAction SilentlyContinue)) {
        $moduleBase = Split-Path -Path $PSScriptRoot -Parent
        $planLogPath = Join-Path $moduleBase 'Public' 'PlanLog.ps1'
        if (Test-Path -LiteralPath $planLogPath) {
            $script:ModuleRoot = $moduleBase
            . $planLogPath
        }
    }

    foreach ($plan in $PlanFiles) {
        try {
            $null = Add-PlanPondLog -PlanPath $plan -Entry @{
                pond   = $Provider
                role   = $Role
                action = $Action
                detail = $Detail
                agent  = $Agent
            }
        } catch {
            $logPath = Join-Path $LanePath 'executor.log'
            $_.Exception.Message | Add-Content -LiteralPath $logPath -Encoding utf8 -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-OpencodeProvider {
    <#
    .SYNOPSIS
        Core implementation used by the Opencode.ps1 script and by tests
        that dot-source this file.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if (-not (Test-Path -LiteralPath $LanePath)) {
        throw "Lane path not found: $LanePath"
    }
    if (-not (Test-Path -LiteralPath $RepoDir)) {
        throw "Repo directory not found: $RepoDir"
    }

    if ($Provider -notin $script:SupportedProviders) {
        throw "OpenCode executor: provider '$Provider' is not supported. Supported: $($script:SupportedProviders -join ', ')."
    }

    # Determine the model, applying provider-specific defaults.
    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = switch ($Provider) {
            'opencode-go' { 'opencode-go/hy3' }
            'opencode'    { 'opencode/hy3-free' }
            default       { 'opencode/hy3-free' }
        }
    }

    if ($Model -notin $script:SupportedModels[$Provider]) {
        throw "OpenCode executor: model '$Model' is not supported for provider '$Provider'. Supported: $($script:SupportedModels[$Provider] -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = if ($Provider -eq 'opencode-go' -and $Model -eq 'opencode-go/mimo-v2.5') {
            'default'
        } elseif ($Provider -eq 'opencode' -and $Model -eq 'opencode/mimo-v2.5-free') {
            'default'
        } else {
            'max'
        }
    }

    $credential = Resolve-OpencodeCredential
    if (-not [string]::IsNullOrWhiteSpace($credential)) {
        [Environment]::SetEnvironmentVariable('OPENCODE_GO_KEY', $credential, 'Process')
    }

    # Prevent OpenCode from loading local skills (e.g. Devin-SalmonRun-Code)
    # so that the Salmon Run orchestrator's own prompt and role contract
    # control the run. These only affect this child process.
    [Environment]::SetEnvironmentVariable('OPENCODE_DISABLE_CLAUDE_CODE_SKILLS', 'true', 'Process')
    [Environment]::SetEnvironmentVariable('OPENCODE_DISABLE_EXTERNAL_SKILLS', '1', 'Process')

    $prompt = Get-OpencodeRolePrompt -Role $Role -RepoDir $RepoDir

    $outLog = Join-Path $LanePath 'opencode.log'
    $errLog = Join-Path $LanePath 'opencode.err'

    $argumentList = @(
        'run'
        $prompt
        '--model', $Model
        '--variant', $Effort
        '--auto'
        '--pure'
    )
    foreach ($pf in $PlanFiles) {
        $argumentList += '-f'
        $argumentList += $pf
    }

    # Resolve the real OpenCode executable. `Start-Process -ArgumentList` does
    # not pass arguments correctly through `opencode.cmd`, and the extension-less
    # `opencode` shim is a POSIX shell script. Prefer the native `.exe` next to
    # the `opencode-ai` package, then use `opencode.ps1` via `pwsh`, and fall back
    # to the bare binary name if nothing else is available.
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    $cliPath = 'opencode'
    if ($onWindows) {
        $ps1Path = (Get-Command 'opencode.ps1' -ErrorAction SilentlyContinue)?.Source
        if ($ps1Path) {
            $exePath = Join-Path (Split-Path (Split-Path $ps1Path -Parent) -Parent) 'opencode-ai\bin\opencode.exe'
            if (Test-Path -LiteralPath $exePath) {
                $cliPath = $exePath
            } else {
                $cliPath = 'pwsh'
                $argumentList = @('-NoProfile','-NonInteractive','-File', $ps1Path) + $argumentList
            }
        } else {
            $cmdPath = (Get-Command 'opencode.cmd' -ErrorAction SilentlyContinue)?.Source
            if ($cmdPath) { $cliPath = $cmdPath }
        }
    }

    # On Windows, prepend the Git for Windows POSIX tool directories so the
    # child shell can resolve head, grep, find, cat, etc. This is necessary
    # because opencode agents frequently emit POSIX pipeline commands.
    $toolPath = Resolve-OpencodeWindowsToolPath
    if ($toolPath) {
        $env:PATH = "$toolPath$([System.IO.Path]::PathSeparator)$($env:PATH)"
        Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model effort=$Effort cli=$cliPath path-prepended=$toolPath"
    } else {
        Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model effort=$Effort cli=$cliPath"
    }

    $process = $null
    $exitCode = 1
    $timeoutKilled = $false

    # The opencode CLI may spawn a long-lived OpenCode desktop process.
    # Record PIDs that exist before this run so we can clean up only the
    # processes started on behalf of this lane.
    $runStart = Get-Date
    $openCodeBefore = @(@(Get-Process -Name OpenCode -ErrorAction SilentlyContinue) | Select-Object Id, StartTime)

    try {
        $process = Start-Process -FilePath $cliPath -ArgumentList $argumentList `
            -WorkingDirectory $RepoDir `
            -RedirectStandardOutput $outLog `
            -RedirectStandardError $errLog `
            -NoNewWindow -PassThru -ErrorAction Stop

        if ($process) {
            $process.Id.ToString() | Set-Content -LiteralPath (Join-Path $LanePath '.pid') -Encoding utf8 -NoNewline
        }

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline -and $process -and -not $process.HasExited) {
            Start-Sleep -Seconds 1
        }

        if ($process -and -not $process.HasExited) {
            $null = taskkill /T /F /PID $process.Id 2>&1 | Out-Null
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $timeoutKilled = $true
            $exitCode = 1
        } else {
            if ($process) {
                # Give the OS a moment to settle the process exit code.
                Start-Sleep -Milliseconds 500
                $exitCode = $process.ExitCode
            } else {
                $exitCode = 1
            }
        }

        if (Test-Path -LiteralPath $errLog) {
            $errText = Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue
            if ($errText) {
                "`n--- stderr ---`n$errText" | Add-Content -LiteralPath $outLog -Encoding utf8 -ErrorAction SilentlyContinue
            }
        }
    } catch {
        $_.Exception.Message | Set-Content -LiteralPath $errLog -Encoding utf8 -NoNewline
        $exitCode = 1
    } finally {
        # Ensure the child opencode process does not outlive this wrapper.
        if ($process -and -not $process.HasExited) {
            $null = taskkill /T /F /PID $process.Id 2>&1 | Out-Null
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    if ($exitCode -eq 0 -and -not (Test-PondExecutorVerdict -Role $Role -PlanFiles $PlanFiles)) {
        $exitCode = 2
    } elseif ($exitCode -eq 0) {
        Write-RolePondLogEntry -Role $Role -PlanFiles $PlanFiles -Provider $Provider -Model $Model
    }
    $resultAction = if ($exitCode -eq 0) { 'external-complete' } elseif ($timeoutKilled) { 'external-timeout' } else { 'external-fail' }
    Write-PlanLog -Action $resultAction -Detail "exit=$exitCode"

    # Clean up any OpenCode desktop processes spawned during this run.
    # They can outlive the CLI and hold files open, blocking Pester cleanup.
    try {
        foreach ($p in @(Get-Process -Name OpenCode -ErrorAction SilentlyContinue)) {
            $known = @($openCodeBefore | Where-Object { $_.Id -eq $p.Id })
            if ($known.Count -eq 0 -and $p.StartTime -and $p.StartTime -ge $runStart) {
                $null = Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }

    $completeFile = Join-Path $LanePath '.complete'
    $failedFile = Join-Path $LanePath '.failed'

    if ($exitCode -eq 0) {
        '1' | Set-Content -LiteralPath $completeFile -Encoding utf8 -NoNewline
        return 0
    } else {
        # The actual provider exit code is preserved in the PondLog detail.
        # The process exit code is normalized to 1 so callers (including the
        # outer Start-PondExecutor) treat any non-zero as a failure.
        '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-OpencodeProvider)
    } catch {
        $err = $_.Exception.Message
        if (Test-Path -LiteralPath $LanePath) {
            $failedFile = Join-Path $LanePath '.failed'
            '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline
            $logPath = Join-Path $LanePath 'executor.log'
            "ERROR: $err" | Set-Content -LiteralPath $logPath -Encoding utf8 -NoNewline
        }
        exit 1
    }
}
