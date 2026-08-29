#Requires -Version 7.0
<#
.SYNOPSIS
    DeepSeek (DSH) harness executor for the salmon-run PondEngine.

.DESCRIPTION
    Runs the `dsh` CLI for the `deepseek` harness. One executor covers the
    entire harness; the `Provider` parameter selects the inference provider
    (`dsh`, `openrouter`, or `deepinfra`).

    The executor:
      - resolves the provider-specific API key
      - sets `DEEPSEEK_API_KEY` and `DEEPSEEK_BASE_URL` for dsh's
        `llm-deepseek` plugin
      - builds a `--patch` overlay that selects the provider-specific model
      - runs `dsh --profile headless --patch <file> <prompt>`

    Supported model aliases (canonical):
      - deepseek-v4-flash
      - deepseek-v4-pro

    The executor maps those canonical names to provider-specific model slugs:
      - dsh       -> deepseek-v4-flash / deepseek-v4-pro
      - openrouter -> deepseek/deepseek-v4-flash / deepseek/deepseek-v4-pro-0813
      - deepinfra  -> deepseek-ai/DeepSeek-V4-Flash-0731 / deepseek-ai/DeepSeek-V4-Pro

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

    [ValidateSet('dsh','openrouter','deepinfra')]
    [string]$Provider = 'dsh',

    [string]$Model,

    [string]$Effort,

    [int]$TimeoutMinutes = 30,

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PondVerdict.ps1')

$script:SupportedProviders = @('dsh','openrouter','deepinfra')

$script:ModelMap = @{
    'dsh' = @{
        'deepseek-v4-flash' = 'deepseek-v4-flash'
        'deepseek-v4-pro'   = 'deepseek-v4-pro'
    }
    'openrouter' = @{
        'deepseek-v4-flash' = 'deepseek/deepseek-v4-flash'
        'deepseek-v4-pro'   = 'deepseek/deepseek-v4-pro-0813'
    }
    'deepinfra' = @{
        'deepseek-v4-flash' = 'deepseek-ai/DeepSeek-V4-Flash-0731'
        'deepseek-v4-pro'   = 'deepseek-ai/DeepSeek-V4-Pro'
    }
}

$script:ProviderBaseUrls = @{
    'dsh'        = $null  # use dsh default (https://api.deepseek.com)
    'openrouter' = 'https://openrouter.ai/api/v1'
    'deepinfra'  = 'https://api.deepinfra.com/v1/openai'
}

$script:ProviderCredentialNames = @{
    'dsh'        = 'DEEPSEEK_API_KEY'
    'openrouter' = 'OPENROUTER_API_KEY'
    'deepinfra'  = 'DEEPINFRA_API_KEY'
}

function Resolve-DshCredential {
    param([string]$Provider)

    $envName = $script:ProviderCredentialNames[$Provider]
    $key = $null
    if (Get-Command Get-SalmonRunCredential -ErrorAction SilentlyContinue) {
        try {
            $key = Get-SalmonRunCredential -Name $envName
        } catch {
            $key = $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = [Environment]::GetEnvironmentVariable($envName, 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "DSH executor: $envName is not configured. Provide it in ~/.salmon/.env or as an environment variable."
    }
    return $key
}

function Get-DshRolePrompt {
    param([string]$Role)
    switch ($Role) {
        'reviewer'        { return 'Review the following salmon-run plan and suggest any improvements.' }
        'auditor'         { return 'Audit the following salmon-run plan for security, privacy, and best-practice issues.' }
        'qa'              { return 'QA the following salmon-run plan. Verify it is complete, testable, and free of defects.' }
        'planner'         { return 'Plan the following salmon-run request. Break it into clear, actionable steps.' }
        'project'         { return 'Manage the following salmon-run project plan and report progress.' }
        'project-planner' { return 'Plan the following salmon-run project. Break it into child work items.' }
        'project-reviewer'{ return 'Review the integrated project and all child evidence. Append **ProjectReviewDecision**: pass and **ProjectReview**: passed by dsh only when the project works as a whole; otherwise append **ProjectReviewDecision**: rework and the reason.' }
        'investigator'    { return 'Investigate the Salmon Run orchestrator failure described in the attached plan. Reproduce it with Pester, fix the root cause in the public salmon-run repository, commit and push the fix, then append **InvestigatorDecision**: pass and **Investigated**: passed by dsh with a summary. If you cannot fix it, append **InvestigatorDecision**: fail and **Investigated**: failed by dsh with the blocker.' }
        default           { return 'Implement the following salmon-run plan.' }
    }
}

function Get-DshTaskPrompt {
    <#
    .SYNOPSIS
        Builds a single task string from the role prompt and the plan files.
    #>
    $parts = @()
    $rolePrompt = Get-DshRolePrompt -Role $Role
    if ($rolePrompt) {
        $parts += $rolePrompt
    }

    foreach ($pf in $PlanFiles) {
        $content = Get-Content -LiteralPath $pf -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($content)) {
            # Avoid a leading "---" token, which the dsh CLI treats as an
            # unknown option. Flatten line breaks so Start-Process does not
            # split the prompt across multiple positional arguments.
            $parts += "plan: $pf"
            $parts += ($content -replace "`r?`n", " ")
        }
    }

    return ($parts -join " ")
}

function Resolve-DshModelSlug {
    <#
    .SYNOPSIS
        Maps a canonical model name to the provider-specific slug expected by
        the inference endpoint. If the caller already passes a provider-specific
        slug, it is returned as-is.
    #>
    param(
        [string]$Provider,
        [string]$Model
    )

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = 'deepseek-v4-flash'
    }

    $map = $script:ModelMap[$Provider]
    if (-not $map) {
        throw "DSH executor: unknown provider '$Provider'."
    }

    if ($map.ContainsKey($Model)) {
        return $map[$Model]
    }

    # Allow provider-specific slugs to be passed through.
    $values = $map.Values
    if ($Model -in $values) {
        return $Model
    }

    throw "DSH executor: model '$Model' is not supported for provider '$Provider'. Supported canonical names: $($map.Keys -join ', ')."
}

function New-DshPatchFile {
    <#
    .SYNOPSIS
        Creates a temporary --patch YAML file that tells dsh which model and
        inference endpoint to use.
    #>
    param(
        [string]$Provider,
        [string]$ModelSlug
    )

    $baseUrl = $script:ProviderBaseUrls[$Provider]

    $contextWindow = 1000000
    $maxTokens     = 256000

    $modelName = switch ($ModelSlug) {
        'deepseek-v4-flash' { 'DeepSeek-V4-Flash' }
        'deepseek-v4-pro'   { 'DeepSeek-V4-Pro' }
        'deepseek/deepseek-v4-flash' { 'OpenRouter DeepSeek V4 Flash' }
        'deepseek/deepseek-v4-pro-0813' { 'OpenRouter DeepSeek V4 Pro' }
        'deepseek-ai/DeepSeek-V4-Flash-0731' { 'DeepInfra DeepSeek V4 Flash' }
        'deepseek-ai/DeepSeek-V4-Pro' { 'DeepInfra DeepSeek V4 Pro' }
        default { $ModelSlug }
    }

    $llmConfigLines = @(
        "- id: llm-deepseek",
        "  config:",
        "    apiKeyEnv: DEEPSEEK_API_KEY"
    )

    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $llmConfigLines += "    baseURL: `"$baseUrl`""
    }

    $llmConfigLines += @(
        "    models:",
        "      - id: `"$ModelSlug`"",
        "        name: `"$modelName`"",
        "        contextWindow: $contextWindow",
        "        maxTokens: $maxTokens"
    )

    $agentConfigLines = @(
        "- id: agent-default-model",
        "  config:",
        "    provider: deepseek-official",
        "    model: `"$ModelSlug`""
    )

    $patch = ($llmConfigLines + $agentConfigLines) -join "`n"
    $tmp = [System.IO.Path]::GetTempFileName() + '.yml'
    $patch | Set-Content -LiteralPath $tmp -Encoding utf8 -NoNewline
    return $tmp
}

function Write-PlanLog {
    param(
        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Detail,

        [string]$Agent = "dsh-$Provider"
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

function Invoke-DshProvider {
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
        throw "DSH executor: provider '$Provider' is not supported. Supported: $($script:SupportedProviders -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = 'max'
    }

    $modelSlug = Resolve-DshModelSlug -Provider $Provider -Model $Model

    $credential = Resolve-DshCredential -Provider $Provider
    [Environment]::SetEnvironmentVariable('DEEPSEEK_API_KEY', $credential, 'Process')

    $baseUrl = $script:ProviderBaseUrls[$Provider]
    if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
        [Environment]::SetEnvironmentVariable('DEEPSEEK_BASE_URL', $baseUrl, 'Process')
    } else {
        [Environment]::SetEnvironmentVariable('DEEPSEEK_BASE_URL', $null, 'Process')
    }

    $patchFile = $null
    try {
        $patchFile = New-DshPatchFile -Provider $Provider -ModelSlug $modelSlug

        $taskPrompt = Get-DshTaskPrompt

        $outLog = Join-Path $LanePath 'dsh.log'
        $errLog = Join-Path $LanePath 'dsh.err'

        # On Windows, the `dsh` npm wrapper is installed as both `dsh.cmd`
        # and `dsh.ps1`. The .cmd wrapper can hang when its output is
        # redirected by Start-Process, so prefer the PowerShell wrapper when
        # it is available.
        $onWindows = $IsWindows -or $env:OS -eq 'Windows_NT'
        $cliPath = 'dsh'
        $argumentList = @('--profile','headless','--patch',$patchFile)
        if ($onWindows) {
            $ps1Path = (Get-Command 'dsh.ps1' -ErrorAction SilentlyContinue)?.Source
            if ($ps1Path) {
                $cliPath = 'pwsh'
                $argumentList = @('-NoProfile','-NonInteractive','-File', $ps1Path, '--profile','headless','--patch',$patchFile)
            } else {
                $cmdPath = (Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue)?.Source
                if ($cmdPath) {
                    $cliPath = $cmdPath
                }
            }
        }

        # The task prompt is the final positional argument. It is already a
        # single, space-flattened string so it is passed as one array element.
        $argumentList += $taskPrompt

        Write-PlanLog -Action 'spawn' -Detail "provider=$Provider model=$Model mapped=$modelSlug effort=$Effort cli=$cliPath"

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
        if ($patchFile -and (Test-Path -LiteralPath $patchFile)) {
            Remove-Item -LiteralPath $patchFile -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Invoke-DshProvider)
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
