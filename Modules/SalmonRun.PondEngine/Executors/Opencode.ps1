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
. (Join-Path $PSScriptRoot 'PondVerdict.ps1')

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
        Returns a detailed, role-specific prompt that encodes the Salmon Run
        evidence and workflow contract for the opencode agent.
    #>
    param(
        [string]$Role,
        [string]$RepoDir
    )

    $common = @"
You are a Salmon Run pond agent. You are running in the target code repository:
  $RepoDir

The attached plan file(s) live in the Salmon Run task queue (`.salmon/Tasks/*`).
Read the attached plan file(s), perform your role in the target repository, then
edit the same attached plan file(s) to append the required evidence. Treat the
target repository as your working directory. Do not modify any other files under
`.salmon` except to append evidence to the attached plan file(s).

You must proceed autonomously and not ask clarifying questions. Do not claim
success unless you actually performed the work. Do not write `**.complete**`
sentinels; the Salmon Run executor creates those from your exit code. The
orchestrator will commit and push the `.salmon` task repo and the target repo
after you finish.

EVIDENCE RULES
- Preserve the entire existing plan (title, headers, scope, body, and any
  existing **PondLog**). Append evidence only at the end.
- If a **PondLog** fenced json block already exists, add your JSON object as a
  new line inside the existing `[]` array. Do not create a second PondLog block.
- Put the legacy evidence line (e.g. `**Reviewed**: ...`) AFTER the closing
  ``` fence, never inside it.
- Do not leave stray characters after the closing ``` fence.

After completing the work, the very last thing you do is append the correct
legacy evidence header and a `**PondLog**` JSON entry to each attached plan file.
"@

    $taskInstructions = switch ($Role) {
        'reviewer' {
            @"

ROLE: Reviewer
This is a review confirmation gate, NOT an implementation phase. Confirm that the
plan was implemented as specified. If it was, append:

**Reviewed**: passed by opencode-go/hy3

to the plan file and add a ``review`` action to the **PondLog**. Do not change
code. If the implementation is missing or wrong, append:

**Reviewed**: failed by opencode-go/hy3 - <reason>

Also append a `## Feedback for Coder` section at the end of the plan (before the
**PondLog**) with these fields:

**Source**: Review
**Verdict**: failed
**FailedChecks**: A numbered list of each check you performed and the concrete result (e.g. "1. scripts/validate-sitemap.mjs missing -- npm script exits with 'Cannot find module'").
**FixActions**: A numbered list of specific, actionable steps the Coder must take to resolve every failed check.

and add a ``review`` action with the failure reason. Leave the plan in the Review
queue; the orchestrator will route the feedback to the previous gate.
"@
        }
        'auditor' {
            @"

ROLE: Auditor
Run the lint / fix-code-smell stage on the target repository. Address
readability, naming, and safe refactor opportunities that improve testability
without changing behavior or outputs. You may run fast syntax/type checks, but
do NOT run the full test suite, do NOT start servers, and do NOT run long-lived
watch/build processes. Update the plan's **ConnascenceScope** if you touch
additional files. After auditing, append:

**Audit**: passed by opencode-go/hy3

and add an ``audit`` action to the **PondLog**. If you cannot pass, append:

**Audit**: failed by opencode-go/hy3 - <reason>

Also append a `## Feedback for Coder` section with these fields:

**Source**: Audit
**Verdict**: failed
**FailedChecks**: A numbered list of each lint/type/test check that failed.
**FixActions**: A numbered list of the concrete code-smell fixes the Coder must apply.
"@
        }
        'qa' {
            @"

ROLE: QA
Adapt and run the property-based testing unit pipeline for the target code. Fix
failing tests. Then run mutation testing and improve the mutation score to at
least 95%, approaching 100% where reasonable. Behavior-preserving refactoring is
allowed if it improves testability. Update **ConnascenceScope** with any new or
changed files. After QA passes, append:

**QA**: passed by opencode-go/hy3

and add a ``qa`` action to the **PondLog**. If QA cannot pass, append:

**QA**: failed by opencode-go/hy3 - <reason>

Also append a `## Feedback for Coder` section with these fields:

**Source**: QA
**Verdict**: failed
**FailedChecks**: A numbered list of the test/mutation/quality checks that failed, with error messages or score shortfalls.
**FixActions**: A numbered list of the code changes, test additions, or refactors needed to make each check pass.
"@
        }
        'planner' {
            @"

ROLE: Planner
Decompose the request in the plan file into clear, actionable steps inside the
target repository. Append a ``plan`` action to the **PondLog**. You do not need to
implement.
"@
        }
        default {
            @"

ROLE: Coder
Before implementing, read the attached plan file for prior failure evidence:

1. Look for a `## Feedback for Coder` section. If it exists, read the
   **FailedChecks** to understand what failed, then treat the **FixActions**
   list as your primary task list. Address every FixAction explicitly and record
   evidence in the plan that each item is resolved.
2. If no feedback section exists, scan for the most recent failed legacy evidence
   headers such as:
   - `**Reviewed**: failed by ... - <reason>`
   - `**QA**: failed by ... - <reason>`
   - `**Audit**: failed by ... - <reason>`
   - `**Implementation**: failed by ... - <reason>`
   Treat the `<reason>` as the highest-priority rework specification.
3. If no prior failure evidence is present, implement the plan body and the
   **Validation Rubric** normally.

Update the plan's **ConnascenceScope** with the exact relative paths of files you
create or modify (no broad commits). After implementing, append:

**Implementation**: completed by opencode-go/hy3

Include a brief summary of what changed, including how any prior feedback was
resolved. Add an ``implement`` action to the **PondLog**. If you cannot complete,
append `**Implementation**: failed by opencode-go/hy3 - <reason>` instead and
stop without writing `.complete`.
"@
        }
    }

    $evidenceMap = @{
        'reviewer' = @('Reviewed', 'review', 'Review')
        'auditor'  = @('Audit', 'audit', 'Audit')
        'qa'       = @('QA', 'qa', 'QA')
        'project-reviewer' = @('ProjectReview', 'review', 'ProjectReview')
        'planner'  = @($null, 'plan', 'Project')
        default    = @('Implementation', 'implement', 'Code')
    }
    $evidenceInfo = if ($evidenceMap.ContainsKey($Role)) { $evidenceMap[$Role] } else { $evidenceMap['default'] }
    $evidenceHeader = $evidenceInfo[0]
    $evidenceAction = $evidenceInfo[1]
    $evidencePond   = $evidenceInfo[2]
    $passVerb       = if ($Role -eq 'coder' -or $Role -eq 'planner') { 'completed' } else { 'passed' }

    $evidence = @"

EVIDENCE FORMAT
For this $Role gate, append exactly one legacy evidence line, one `## Feedback
for Coder` section when failing, and one **PondLog** JSON entry at the end of
each attached plan file.
"@

    if ($evidenceHeader) {
        $evidence += @"

The legacy evidence line must be:

**$evidenceHeader**: $passVerb by opencode-go/hy3

If the evidence line is not a $passVerb result, use:

**$evidenceHeader**: failed by opencode-go/hy3 - <reason>
"@
    }

    $evidence += @"

The **PondLog** entry must be a JSON object on its own line inside the existing
`PondLog` JSON array (create a `**PondLog**` fenced json block if none exists):

```json
{ "ts": "<ISO-8601>", "pond": "$evidencePond", "role": "$Role", "action": "$evidenceAction", "detail": "$passVerb by opencode-go/hy3", "agent": "opencode-go/hy3" }
```
"@

    return "$common`n$taskInstructions`n$evidence"
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
    }
    $resultAction = if ($exitCode -eq 0) { 'external-complete' } elseif ($timeoutKilled) { 'external-timeout' } else { 'external-fail' }
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
