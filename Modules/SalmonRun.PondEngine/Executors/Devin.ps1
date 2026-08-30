<#
.SYNOPSIS
    Devin provider executor for the salmon-run PondEngine.

.DESCRIPTION
    Runs the `devin` CLI. It resolves `DEVIN_API_KEY`, builds
    `devin run --command work-{role}-once --model {model} --effort {effort}
    --files {plan1} ...`, and captures the result.

    The adapter appends `spawn`, `external-complete`, and `external-fail`
    events to each plan's **PondLog**, and writes a `.complete` sentinel on
    success or a `.failed` sentinel on any non-zero outcome.

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

    [string]$Provider = 'devin',

    [string]$Model,

    [string]$Effort,

    [int]$TimeoutMinutes = 30,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PondVerdict.ps1')
. (Join-Path $PSScriptRoot 'RolePrompts.ps1')

$script:SupportedProviders = @('devin')
$script:SupportedModels = @('swe-1-7')

function Resolve-DevinCredential {
    $key = $null
    if (Get-Command Get-SalmonRunCredential -ErrorAction SilentlyContinue) {
        try {
            $key = Get-SalmonRunCredential -Name 'DEVIN_API_KEY'
        } catch {
            $key = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = $env:DEVIN_API_KEY
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Devin executor: DEVIN_API_KEY is not configured. Provide it in ~/.salmon/.env or as an environment variable."
    }
    return $key
}

function Write-PlanLog {
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Detail,

        [string]$Agent = 'devin'
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

function Get-DevinRolePrompt {
    <#
    .SYNOPSIS
        Returns the shared Salmon Run role prompt for the Devin provider.
    #>
    param([string]$Role)
    return Get-RolePrompt -Role $Role -RepoDir $RepoDir -Provider $Provider -Model $Model
}

function New-DevinPromptFile {
    <#
    .SYNOPSIS
        Builds a single prompt file from the role prompt and the plan files.
        devin.exe accepts --prompt-file for non-interactive use.
    #>
    $parts = @()
    $rolePrompt = Get-DevinRolePrompt -Role $Role
    if ($rolePrompt) {
        $parts += $rolePrompt
    }

    foreach ($pf in $PlanFiles) {
        $content = Get-Content -LiteralPath $pf -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            $parts += "--- plan: $pf ---"
            $parts += $content
        }
    }

    $prompt = $parts -join "`n`n"
    $tmp = [System.IO.Path]::GetTempFileName() + '.md'
    $prompt | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    return $tmp
}

function Invoke-DevinProvider {
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
        throw "Devin executor: provider '$Provider' is not supported. Supported: $($script:SupportedProviders -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = 'swe-1-7'
    }

    if ($Model -notin $script:SupportedModels) {
        throw "Devin executor: model '$Model' is not supported. Supported: $($script:SupportedModels -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = 'medium'
    }

    $credential = Resolve-DevinCredential
    [Environment]::SetEnvironmentVariable('DEVIN_API_KEY', $credential, 'Process')

    $outLog = Join-Path $LanePath 'devin.log'
    $errLog = Join-Path $LanePath 'devin.err'

    $promptFile = $null
    try {
        $promptFile = New-DevinPromptFile

        $argumentList = @(
            '--prompt-file', $promptFile
            '-p'
            '--model', $Model
            '--permission-mode', 'accept-edits'
            '--respect-workspace-trust', 'false'
        )

        # If an effort hint is useful for future devin versions, keep it as an
        # extra flag. Current devin.exe does not expose --effort, so we log it
        # but do not include it in the argument list.
        Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model effort=$Effort"

        $process = $null
        $exitCode = 1
        try {
            $process = Start-Process -FilePath 'devin' -ArgumentList $argumentList `
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

        if ($exitCode -eq 0 -and -not (Test-PondExecutorVerdict -Role $Role -PlanFiles $PlanFiles)) {
            $exitCode = 2
        } elseif ($exitCode -eq 0) {
            Write-RolePondLogEntry -Role $Role -PlanFiles $PlanFiles -Provider $Provider -Model $Model
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
    } finally {
        if ($promptFile -and (Test-Path -LiteralPath $promptFile)) {
            Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-DevinProvider)
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
