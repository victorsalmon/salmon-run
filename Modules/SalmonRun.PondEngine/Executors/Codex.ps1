#Requires -Version 7.0
<#
.SYNOPSIS
    OpenAI Codex CLI executor for the salmon-run PondEngine.

.DESCRIPTION
    Runs the `codex exec` CLI for the `codex` harness. It uses the
    `gpt-5.6-luna` model (and the rest of the gpt-5.6 family) by default,
    maps `Effort` to Codex's `model_reasoning_effort`, and pipes a prompt
    built from the plan files via stdin.

    The command shape is:

        codex exec -m <model> -C <RepoDir> \
            -c model_reasoning_effort=<effort> \
            --skip-git-repo-check --ephemeral \
            --output-last-message <lane>/codex.out -

    The trailing `-` tells `codex exec` to read the prompt from stdin. The
    executor builds a temporary prompt file from the role-specific prefix and
    the content of each plan file, then redirects that file to the CLI's
    stdin.

    Credentials:
    - If `OPENAI_API_KEY` is set (via SalmonRun.Credentials or the process
      environment), it is exported for the CLI.
    - If it is not set, the executor still runs; the `codex` CLI will use
      the user's existing `codex login` session or `~/.codex/config.toml`.

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

    [ValidateSet('codex')]
    [string]$Provider = 'codex',

    [string]$Model,

    [string]$Effort,

    [int]$TimeoutMinutes = 30,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'

$script:SupportedProviders = @('codex')
$script:SupportedModels = @(
    'gpt-5.6-luna',
    'gpt-5.6-terra',
    'gpt-5.6-sol',
    'gpt-5.6'
)

function Resolve-OpenAICredential {
    <#
    .SYNOPSIS
        Resolves OPENAI_API_KEY from SalmonRun.Credentials when available,
        otherwise from the process environment. Returns null if not found.
    #>
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
    return $key
}

function Get-CodexInvocation {
    <#
    .SYNOPSIS
        Resolves the node executable and the Codex CLI entry point.
        Codex is distributed as a PowerShell wrapper (codex.ps1) that shells
        to node. Start-Process cannot run a .ps1 directly, so we locate the
        underlying codex.js and the matching node.exe.
    #>
    $codexCommand = Get-Command 'codex' -ErrorAction SilentlyContinue
    if (-not $codexCommand) {
        throw "Codex executor: 'codex' command not found. Install the Codex CLI and ensure it is on PATH."
    }

    $basedir = Split-Path -Parent $codexCommand.Source
    $nodeExe = Join-Path $basedir 'node.exe'
    if (-not (Test-Path -LiteralPath $nodeExe)) {
        $nodeExe = (Get-Command 'node' -ErrorAction SilentlyContinue).Source
        if (-not $nodeExe) {
            throw "Codex executor: 'node' executable not found."
        }
    }

    $codexJs = Join-Path $basedir 'node_modules/@openai/codex/bin/codex.js'
    if (-not (Test-Path -LiteralPath $codexJs)) {
        throw "Codex executor: cannot find node_modules/@openai/codex/bin/codex.js under '$basedir'."
    }

    return [PSCustomObject]@{
        NodeExe = $nodeExe
        CodexJs = $codexJs
    }
}

function Get-CodexRolePrompt {
    <#
    .SYNOPSIS
        Returns a short role-specific prefix for the codex CLI prompt.
    #>
    param([string]$Role)
    switch ($Role) {
        'reviewer'         { return 'Review the following salmon-run plan and suggest any improvements.' }
        'auditor'          { return 'Audit the following salmon-run plan for security, privacy, and best-practice issues.' }
        'qa'               { return 'QA the following salmon-run plan. Verify it is complete, testable, and free of defects.' }
        'planner'          { return 'Plan the following salmon-run request. Break it into clear, actionable steps.' }
        'project'          { return 'Manage the following salmon-run project plan and report progress.' }
        'project-planner'  { return 'Plan the following salmon-run project. Break it into child work items.' }
        'project-reviewer' { return 'Review the following salmon-run project plan and child work items.' }
        default            { return 'Implement the following salmon-run plan.' }
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

        [string]$Agent = "codex-$Provider"
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
            } -ErrorAction SilentlyContinue
        } catch {
            # PondLog failures must not stop the executor.
        }
    }
}

function New-CodexPromptFile {
    <#
    .SYNOPSIS
        Builds a temporary prompt file from the role prefix and all plan files.
    #>
    $tempFile = Join-Path $LanePath "codex-prompt-$(New-Guid).txt"
    $rolePrompt = Get-CodexRolePrompt -Role $Role

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($rolePrompt)
    $lines.Add('')

    foreach ($plan in $PlanFiles) {
        if (Test-Path -LiteralPath $plan) {
            $lines.Add("--- $plan ---")
            $content = Get-Content -LiteralPath $plan -Raw
            if ($content) {
                $lines.Add($content)
            }
            $lines.Add('')
        }
    }

    Set-Content -LiteralPath $tempFile -Value ($lines -join "`n") -Encoding utf8 -NoNewline
    return $tempFile
}

function Invoke-CodexProvider {
    <#
    .SYNOPSIS
        Core implementation used by the Codex.ps1 script.
    #>
    if ($Provider -notin $script:SupportedProviders) {
        throw "Codex executor: provider '$Provider' is not supported. Supported: $($script:SupportedProviders -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = 'gpt-5.6-luna'
    }

    if ($Model -notin $script:SupportedModels) {
        throw "Codex executor: model '$Model' is not supported. Supported: $($script:SupportedModels -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = 'low'
    }

    if ($Effort -notin @('low','medium','high')) {
        throw "Codex executor: effort '$Effort' is not supported. Supported: low, medium, high."
    }

    $outLog = Join-Path $LanePath 'codex.log'
    $errLog = Join-Path $LanePath 'codex.err'
    $outFile = Join-Path $LanePath 'codex.out'

    $promptFile = $null
    try {
        $promptFile = New-CodexPromptFile

        $credential = Resolve-OpenAICredential
        if (-not [string]::IsNullOrWhiteSpace($credential)) {
            [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $credential, 'Process')
        }

        # Keep Codex's Rust/reqwest trace noise out of the execution logs.
        $oldRustLog = $env:RUST_LOG
        $env:RUST_LOG = 'error'

        Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model effort=$Effort cli=codex"

        $invocation = Get-CodexInvocation

        $argumentList = @(
            $invocation.CodexJs,
            'exec',
            '-m', $Model,
            '-C', $RepoDir,
            '-c', "model_reasoning_effort=$Effort",
            '--skip-git-repo-check',
            '--ephemeral',
            '--output-last-message', $outFile,
            '-'
        )

        $process = $null
        $exitCode = 1
        try {
            $process = Start-Process -FilePath $invocation.NodeExe -ArgumentList $argumentList `
                -WorkingDirectory $RepoDir `
                -RedirectStandardInput $promptFile `
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

            if (Test-Path -LiteralPath $outFile) {
                $outText = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
                if ($outText) {
                    "`n--- codex output ---`n$outText" | Add-Content -LiteralPath $outLog -Encoding utf8 -ErrorAction SilentlyContinue
                }
            }
        } catch {
            $_.Exception.Message | Set-Content -LiteralPath $errLog -Encoding utf8 -NoNewline
            $exitCode = 1
        } finally {
            if (-not [string]::IsNullOrWhiteSpace($oldRustLog)) {
                $env:RUST_LOG = $oldRustLog
            } else {
                [Environment]::SetEnvironmentVariable('RUST_LOG', $null, 'Process')
            }
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
        exit (Invoke-CodexProvider)
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
