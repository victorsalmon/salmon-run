<#
.SYNOPSIS
    OpenCode provider executor for the salmon-run PondEngine.

.DESCRIPTION
    Runs the `opencode` CLI for the `opencode-go` (Ox-Alpha, Mimo) and
    `opencode` (Zen, Hy3) providers. It resolves `OPENCODE_GO_KEY`, builds
    `opencode run --command work-{role}-once --model {model} --effort {effort}
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

    [ValidateSet('opencode','opencode-go')]
    [string]$Provider = 'opencode',

    [string]$Model,

    [string]$Effort,

    [int]$TimeoutMinutes = 30,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'

function Resolve-OpencodeCredential {
    <#
    .SYNOPSIS
        Resolves OPENCODE_GO_KEY from SalmonRun.Credentials when available,
        otherwise from the process environment.
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
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "OpenCode executor: OPENCODE_GO_KEY is not configured. Provide it in ~/.salmon/.env or as an environment variable."
    }
    return $key
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

    # Determine the model and effort, applying provider-specific defaults.
    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = switch ($Provider) {
            'opencode-go' { 'opencode-go/ox-alpha-free' }
            'opencode'    { 'opencode/hy3-free' }
            default       { 'opencode/hy3-free' }
        }
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
    [Environment]::SetEnvironmentVariable('OPENCODE_GO_KEY', $credential, 'Process')

    $outLog = Join-Path $LanePath 'opencode.log'
    $errLog = Join-Path $LanePath 'opencode.err'

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
        $process = Start-Process -FilePath 'opencode' -ArgumentList $argumentList `
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
