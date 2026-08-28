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
    [ValidateSet('coder','reviewer','auditor','qa','planner','project','project-planner','project-reviewer')]
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

function Get-OpencodeRolePrompt {
    <#
    .SYNOPSIS
        Returns a short role-specific prompt for the opencode CLI.
    #>
    param([string]$Role)
    switch ($Role) {
        'reviewer'        { return 'Review the following salmon-run plan and suggest any improvements.' }
        'auditor'         { return 'Audit the following salmon-run plan for security, privacy, and best-practice issues.' }
        'qa'              { return 'QA the following salmon-run plan. Verify it is complete, testable, and free of defects.' }
        'planner'         { return 'Plan the following salmon-run request. Break it into clear, actionable steps.' }
        'project'         { return 'Manage the following salmon-run project plan and report progress.' }
        'project-planner' { return 'Plan the following salmon-run project. Break it into child work items.' }
        'project-reviewer'{ return 'Review the following salmon-run project plan and child work items.' }
        default           { return 'Implement the following salmon-run plan.' }
    }
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

    $prompt = Get-OpencodeRolePrompt -Role $Role

    $outLog = Join-Path $LanePath 'opencode.log'
    $errLog = Join-Path $LanePath 'opencode.err'

    $argumentList = @(
        'run'
        $prompt
        '--model', $Model
        '--variant', $Effort
        '--auto'
    )
    foreach ($pf in $PlanFiles) {
        $argumentList += '-f'
        $argumentList += $pf
    }

    # On Windows, the `opencode` npm wrapper is installed as `opencode.cmd`;
    # the extension-less `opencode` file is a POSIX shell script that Windows
    # cannot execute directly. Resolve the correct executable.
    $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
    $cliPath = 'opencode'
    if ($onWindows) {
        $cmdPath = (Get-Command 'opencode.cmd' -ErrorAction SilentlyContinue)?.Source
        if ($cmdPath) {
            $cliPath = $cmdPath
        } else {
            $ps1Path = (Get-Command 'opencode.ps1' -ErrorAction SilentlyContinue)?.Source
            if ($ps1Path) {
                $cliPath = 'pwsh'
                $argumentList = @('-NoProfile','-NonInteractive','-File', $ps1Path) + $argumentList
            }
        }
    }

    Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model effort=$Effort cli=$cliPath"

    $process = $null
    $exitCode = 1
    try {
        $process = Start-Process -FilePath $cliPath -ArgumentList $argumentList `
            -WorkingDirectory $RepoDir `
            -RedirectStandardOutput $outLog `
            -RedirectStandardError $errLog `
            -NoNewWindow -PassThru -ErrorAction Stop

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline -and $process -and -not $process.HasExited) {
            Start-Sleep -Seconds 1
        }

        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
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
    }

    $resultAction = if ($exitCode -eq 0) { 'external-complete' } else { 'external-fail' }
    Write-PlanLog -Action $resultAction -Detail "exit=$exitCode"

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
