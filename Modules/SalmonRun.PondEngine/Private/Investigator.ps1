#Requires -Version 7.0

function Get-PondFeedbackFailureCounterPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$TaskRoot = (Get-SalmonTaskRoot)
    )
    $logDir = Join-Path $TaskRoot 'Logs'
    $null = New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue
    return (Join-Path $logDir 'feedback-failure-counter.json')
}

function Get-PondFeedbackFailureCounter {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$TaskRoot = (Get-SalmonTaskRoot)
    )
    $path = Get-PondFeedbackFailureCounterPath -TaskRoot $TaskRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return @{
            count = 0
            investigatorPending = $false
            lastFailureAt = $null
            lastInvestigatorAt = $null
        }
    }
    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($json) {
            if (-not $json.ContainsKey('count')) { $json['count'] = 0 }
            if (-not $json.ContainsKey('investigatorPending')) { $json['investigatorPending'] = $false }
            if (-not $json.ContainsKey('lastFailureAt')) { $json['lastFailureAt'] = $null }
            if (-not $json.ContainsKey('lastInvestigatorAt')) { $json['lastInvestigatorAt'] = $null }
            return $json
        }
    } catch {
        Write-Verbose "Get-PondFeedbackFailureCounter: failed to read $path : $_"
    }
    return @{
        count = 0
        investigatorPending = $false
        lastFailureAt = $null
        lastInvestigatorAt = $null
    }
}

function Set-PondFeedbackFailureCounter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Counter,

        [string]$TaskRoot = (Get-SalmonTaskRoot)
    )
    $path = Get-PondFeedbackFailureCounterPath -TaskRoot $TaskRoot
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force -ErrorAction SilentlyContinue
    ($Counter | ConvertTo-Json -Compress) | Set-Content -LiteralPath $path -Encoding utf8 -NoNewline
}

function Test-PondInvestigatorPending {
    <#
    .SYNOPSIS
        Returns true if an Investigator plan is currently pending or in progress.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$TaskRoot
    )
    $counter = Get-PondFeedbackFailureCounter -TaskRoot $TaskRoot
    if ($counter.investigatorPending) { return $true }

    $investigateDir = Join-Path $TaskRoot 'Investigate'
    if (Test-Path -LiteralPath $investigateDir) {
        $plans = @(Get-ChildItem -LiteralPath $investigateDir -File -Filter '*.md' -ErrorAction SilentlyContinue)
        foreach ($plan in $plans) {
            $content = Get-Content -LiteralPath $plan.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -notmatch '\*\*Status\*\*:\s*(completed|failed)') {
                return $true
            }
        }
    }

    $workingDir = Join-Path $TaskRoot 'Working'
    if (Test-Path -LiteralPath $workingDir) {
        $lanes = @(Get-ChildItem -LiteralPath $workingDir -Directory -Filter '*investigator*' -ErrorAction SilentlyContinue)
        if ($lanes.Count -gt 0) { return $true }
    }

    return $false
}

function New-PondInvestigatorPlan {
    <#
    .SYNOPSIS
        Creates an Investigator plan in the Investigate queue.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$TaskRoot,

        [int]$FailureCount = 0,

        [string]$Reason = 'Recurring feedback failures detected.'
    )
    $investigateDir = Join-Path $TaskRoot 'Investigate'
    $null = New-Item -ItemType Directory -Path $investigateDir -Force -ErrorAction SilentlyContinue

    $codeDir = Join-Path $TaskRoot 'Code'
    $feedbackPlans = @()
    if (Test-Path -LiteralPath $codeDir) {
        $feedbackPlans = @(Get-ChildItem -LiteralPath $codeDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '-feedback\d+\.md$' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 5)
    }

    $summaryLines = foreach ($fp in $feedbackPlans) {
        $content = Get-Content -LiteralPath $fp.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) { continue }
        $failedStage = if ($content -match '\*\*FailedStage\*\*:\s*(?<v>[^\r\n]+)') { $Matches['v'].Trim() } else { 'unknown' }
        $parent = if ($content -match '\*\*ParentPlan\*\*:\s*(?<v>[^\r\n]+)') { $Matches['v'].Trim() } else { $fp.BaseName }
        $failedChecks = ''
        if ($content -match '(?im)^## Feedback for Coder\s*$[\s\S]*?\*\*FailedChecks\*\*:\s*(?<fc>[\s\S]*?)(?:\*\*FixActions\*\*:|```|\z)') {
            $failedChecks = ($Matches['fc'].Trim() -replace '\s+', ' ')
            if ($failedChecks.Length -gt 120) { $failedChecks = $failedChecks.Substring(0, 120) + '...' }
        }
        "- $parent ($failedStage): $failedChecks"
    }
    $feedbackSummary = if ($summaryLines) { $summaryLines -join "`n" } else { '- No recent feedback plans on disk.' }

    $planName = "$(Get-Date -Format 'yyyy.MM.dd')-sr-investigate-recurring-feedback.md"
    $planPath = Join-Path $investigateDir $planName

    $content = @(
        "# Session Plan: $planName"
        ''
        '**Status**: ready'
        '**TargetRepo**: sr'
        '**Namespace**: sr'
        '**Scope**: Investigate recurring Salmon Run feedback failures and improve the engine so future plans succeed on the first run.'
        '**PlanType**: investigation'
        "**FailureCountTrigger**: $FailureCount"
        '**ConnascenceScope**: `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`, `Modules/SalmonRun.PondEngine/Public/New-SalmonProjectPlan.ps1`, `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskPlanProject.ps1`'
        '**Files**: `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`, `Modules/SalmonRun.PondEngine/Public/New-SalmonProjectPlan.ps1`, `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskPlanProject.ps1`'
        ''
        '---'
        ''
        '## Investigation target'
        ''
        "The feedback-failure counter has reached $FailureCount. Recent feedback reasons:"
        ''
        $feedbackSummary
        ''
        '## Tasks'
        ''
        '1. Read the recent feedback plans above and identify the two most common failure patterns.'
        '2. Open the `Code` role prompt in `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`. If the instructions are ambiguous, allow skipping tests, or do not require a passing validation rubric before marking `**Implementation**: completed`, improve them so the coder must pass every rubric item on the first run.'
        '3. Open `Modules/SalmonRun.PondEngine/Public/New-SalmonProjectPlan.ps1` and `Modules/SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskPlanProject.ps1`. If session plans are being printed with vague scope, missing acceptance criteria, or unrealistic token budgets, improve the templates so the Coder has a clear, testable, single-run plan.'
        '4. Run the focused Pester tests (`Tests/SalmonRun.PondEngine.Feedback.Tests.ps1`, `Tests/SalmonRun.PondEngine.Tests.ps1`) and the full Pester suite.'
        '5. Commit and push any changes with conventional-commit messages.'
        ''
        '## Evidence'
        ''
        'Append `**InvestigatorDecision**: pass` and `**Investigated**: passed by <agent> - <summary of the root cause and the fix>` to this plan.'
        'Also append a `**PondLog**` entry with action `investigate` and the result.'
        ''
        '**PondLog**'
        ''
        '```json'
        '[]'
        '```'
    ) -join "`n"

    $content | Set-Content -LiteralPath $planPath -Encoding utf8 -NoNewline

    $null = Add-PlanPondLog -PlanPath $planPath -Entry @{
        ts     = (Get-Date -Format 'o')
        pond   = 'Investigate'
        role   = 'investigator'
        action = 'created'
        detail = "investigator for recurring feedback (count=$FailureCount)"
        agent  = 'PondEngine'
    } -ErrorAction Stop

    return (Get-Item -LiteralPath $planPath)
}

function Invoke-PondInvestigatorSpawn {
    <#
    .SYNOPSIS
        Increments the feedback-failure counter and idempotently spawns one
        Investigator plan every time the counter reaches an even number > 0.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [PondContext]$Context
    )
    $taskRoot = $Context.TaskRoot
    $counter = Get-PondFeedbackFailureCounter -TaskRoot $taskRoot
    $counter.count++
    $counter.lastFailureAt = (Get-Date -Format 'o')
    Set-PondFeedbackFailureCounter -Counter $counter -TaskRoot $taskRoot

    if ($counter.count % 2 -ne 0 -or $counter.count -eq 0) { return $null }
    if (Test-PondInvestigatorPending -TaskRoot $taskRoot) { return $null }

    $investigatorPlan = New-PondInvestigatorPlan -TaskRoot $taskRoot -FailureCount $counter.count
    $counter.investigatorPending = $true
    $counter.lastInvestigatorAt = (Get-Date -Format 'o')
    Set-PondFeedbackFailureCounter -Counter $counter -TaskRoot $taskRoot
    return $investigatorPlan
}

function Clear-PondInvestigatorPending {
    [CmdletBinding()]
    param(
        [string]$TaskRoot = (Get-SalmonTaskRoot)
    )
    $counter = Get-PondFeedbackFailureCounter -TaskRoot $TaskRoot
    if ($counter.investigatorPending) {
        $counter.investigatorPending = $false
        Set-PondFeedbackFailureCounter -Counter $counter -TaskRoot $TaskRoot
    }
}
