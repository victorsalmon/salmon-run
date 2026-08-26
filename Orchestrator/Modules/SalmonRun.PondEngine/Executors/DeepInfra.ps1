<#
.SYNOPSIS
    DeepInfra/Codex provider executor for the salmon-run PondEngine.

.DESCRIPTION
    Runs the `codex` CLI for DeepInfra-hosted models. It resolves
    `OPENAI_API_KEY`, builds
    `codex run --command work-{role}-once --model {model} --effort {effort}
    --files {plan1} ...`, and captures the result.

    The adapter appends `spawn`, `external-complete`, and `external-fail`
    events to each plan's **PondLog**, and writes a `.complete` sentinel on
    success or a `.failed` sentinel on any non-zero outcome.

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

    [string]$Provider = 'deepinfra',

    [string]$Model,

    [string]$Effort,

    [int]$TimeoutMinutes = 30,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'

function Resolve-DeepInfraCredential {
    $key = $null
    if (Get-Command Get-SalmonRunCredential -ErrorAction SilentlyContinue) {
        try {
            $key = Get-SalmonRunCredential -Name 'OPENAI_API_KEY'
        } catch {
            $key = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = $env:OPENAI_API_KEY
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "DeepInfra executor: OPENAI_API_KEY is not configured. Provide it in ~/.salmon/.env or as an environment variable."
    }
    return $key
}

function Write-PlanLog {
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Detail,

        [string]$Agent = 'deepinfra'
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

function Invoke-DeepInfraProvider {
    [CmdletBinding()]
    [OutputType([int])]
    param()

    if (-not (Test-Path -LiteralPath $LanePath)) {
        throw "Lane path not found: $LanePath"
    }
    if (-not (Test-Path -LiteralPath $RepoDir)) {
        throw "Repo directory not found: $RepoDir"
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = 'deepseek-ai/DeepSeek-V4-Flash-0731'
    }

    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = 'medium'
    }

    $credential = Resolve-DeepInfraCredential
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $credential, 'Process')

    $outLog = Join-Path $LanePath 'codex.log'
    $errLog = Join-Path $LanePath 'codex.err'

    $argumentList = @(
        'run'
        '--command', "work-$Role-once"
        '--model', $Model
        '--effort', $Effort
        '--files'
    ) + @($PlanFiles)

    Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model effort=$Effort"

    $process = $null
    $exitCode = 1
    try {
        $process = Start-Process -FilePath 'codex' -ArgumentList $argumentList `
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
        '1' | Set-Content -LiteralPath $failedFile -Encoding utf8 -NoNewline
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-DeepInfraProvider)
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
