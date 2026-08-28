<#
.SYNOPSIS
    Public local executor for the salmon-run PondEngine.

.DESCRIPTION
    This is the default executor for the public salmon-run package. It runs
    in-process, accepts a lane of plan files, and writes the completion
    sentinel. It is intended as an integration point: users can replace or
    extend it to call their own local agent CLI, while the PondEngine handles
    queueing, routing, and transitions.

    The canonical evidence for each role is written as a timestamped entry
    in the plan's **PondLog** section. Legacy evidence headers are still
    written for backward compatibility.

    Exit code 0 writes .complete.
    Any non-zero exit or unhandled exception writes .failed.
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

    [string]$Provider = 'local',

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'

try {
    # Dot-source the canonical PlanLog helpers so this executor can run under
    # Windows PowerShell 5.1 without importing the full module manifest.
    $script:ModuleRoot = Convert-Path (Join-Path $PSScriptRoot '..')
    . (Join-Path (Join-Path $script:ModuleRoot 'Public') 'PlanLog.ps1')

    if (-not (Test-Path -LiteralPath $LanePath)) {
        throw "Lane path not found: $LanePath"
    }

    $log = @()
    $log += "[$(Get-Date -Format 'o')] Local executor started for role '$Role'"
    $log += "Lane: $LanePath"
    $log += "Repo: $RepoDir"
    $log += "Plans: $($PlanFiles -join ', ')"

    $roleToPond = @{
        'coder'            = 'Code'
        'reviewer'         = 'Review'
        'auditor'          = 'Audit'
        'qa'               = 'QA'
        'planner'          = 'Intake'
        'project'          = 'Project'
        'project-planner'  = 'Project'
        'project-reviewer' = 'ProjectReview'
    }
    $pondName = if ($roleToPond.ContainsKey($Role)) { $roleToPond[$Role] } else { 'Unknown' }

    function Test-ActionEvidence {
        param(
            [Parameter(Mandatory)]
            [array]$PondLog,

            [Parameter(Mandatory)]
            [string]$Content,

            [Parameter(Mandatory)]
            [string]$Action
        )
        $hasLog = @($PondLog | Where-Object { $null -ne $_ -and $_.action -eq $Action }).Count -gt 0
        $legacyMap = @{
            implement = '(?im)^\*\*Implementation\*\*:'
            review    = '(?im)^\*\*Reviewed\*\*:'
            audit     = '(?im)^\*\*Audit\*\*:'
            qa        = '(?im)^\*\*QA\*\*:'
        }
        $hasLegacy = $false
        if ($legacyMap.ContainsKey($Action)) {
            $hasLegacy = $Content -match $legacyMap[$Action]
        }
        return $hasLog -or $hasLegacy
    }

    foreach ($plan in $PlanFiles) {
        $planName = Split-Path -Leaf $plan
        $planPath = Join-Path $LanePath $planName
        if (-not (Test-Path -LiteralPath $planPath)) { continue }

        $content = Get-Content -LiteralPath $planPath -Raw
        $pondLog = @(Get-PlanPondLog -PlanPath $planPath)

        # Mark the plan as worked on by this role.
        if ($content -notmatch '(?im)^\*\*Agent\*\*:') {
            $content = $content + "`n`n**Agent**: $Role`n"
        }

        # Legacy evidence headers are still written for backward compatibility;
        # the canonical evidence is the timestamped **PondLog** entry appended
        # at the end of this loop.
        $hasOldImplementation = $content -match '(?im)^\*\*Implementation\*\*:'
        $hasOldReviewed       = $content -match '(?im)^\*\*Reviewed\*\*:'
        $hasOldAudit          = $content -match '(?im)^\*\*Audit\*\*:'
        $hasOldQA             = $content -match '(?im)^\*\*QA\*\*:'

        # Coder role records an implementation note.
        if ($Role -eq 'coder' -and -not $hasOldImplementation) {
            $content = $content + "`n**Implementation**: completed by public local executor`n"
        }

        # Reviewer checks that the coder left implementation evidence.
        if ($Role -eq 'reviewer') {
            if (-not (Test-ActionEvidence -PondLog $pondLog -Content $content -Action 'implement')) {
                throw "Plan '$planName' is missing **Implementation** evidence"
            }
            if (-not $hasOldReviewed) {
                $content = $content + "`n**Reviewed**: passed by public local reviewer`n"
            }
        }

        # Auditor runs a lightweight best-practice/secret scan on the plan.
        if ($Role -eq 'auditor') {
            if (-not (Test-ActionEvidence -PondLog $pondLog -Content $content -Action 'review')) {
                throw "Plan '$planName' is missing **Reviewed** evidence"
            }
            $secretPattern = "(?im)(api[_-]?key|apikey|token|secret|password)\s*[:=]\s*(`"(?:[^`"`r`n]{4,})`"|'(?:[^'`r`n]{4,})')"
            if ($content -match $secretPattern) {
                throw "Plan '$planName' appears to contain a credential value"
            }
            if (-not $hasOldAudit) {
                $content = $content + "`n**Audit**: passed by public local auditor`n"
            }
        }

        # QA performs a final evidence check before the plan reaches Complete.
        if ($Role -eq 'qa') {
            if (-not (Test-ActionEvidence -PondLog $pondLog -Content $content -Action 'implement')) {
                throw "Plan '$planName' is missing **Implementation** evidence"
            }
            if (-not (Test-ActionEvidence -PondLog $pondLog -Content $content -Action 'review')) {
                throw "Plan '$planName' is missing **Reviewed** evidence"
            }
            if (-not (Test-ActionEvidence -PondLog $pondLog -Content $content -Action 'audit')) {
                throw "Plan '$planName' is missing **Audit** evidence"
            }
            if (-not $hasOldQA) {
                $content = $content + "`n**QA**: passed by public local qa`n"
            }
        }

        if ($Role -eq 'project-reviewer') {
            $content = $content + "`n**ProjectReviewDecision**: pass`n**ProjectReview**: passed by public local project reviewer`n"
        }

        $content | Set-Content -LiteralPath $planPath -Encoding utf8 -NoNewline

        # Append the canonical timestamped PondLog event for this role.
        $actionMap = @{
            'coder'    = 'implement'
            'reviewer' = 'review'
            'auditor'  = 'audit'
            'qa'       = 'qa'
            'project-reviewer' = 'review'
        }
        if ($actionMap.ContainsKey($Role)) {
            $null = Add-PlanPondLog -PlanPath $planPath -Entry @{
                pond   = $pondName
                role   = $Role
                action = $actionMap[$Role]
                detail = "completed by public local executor"
                agent  = 'PublicLocal'
            } -ErrorAction Stop
        }
    }

    $log += "[$(Get-Date -Format 'o')] Local executor finished successfully"
    $log | Set-Content -LiteralPath (Join-Path $LanePath 'executor.log') -Encoding utf8 -NoNewline

    '1' | Set-Content -LiteralPath (Join-Path $LanePath '.complete') -Encoding utf8 -NoNewline
    exit 0
} catch {
    $err = $_.Exception.Message
    "ERROR: $err" | Set-Content -LiteralPath (Join-Path $LanePath 'executor.log') -Encoding utf8 -NoNewline
    $err | Set-Content -LiteralPath (Join-Path $LanePath '.failed') -Encoding utf8 -NoNewline
    exit 1
}
