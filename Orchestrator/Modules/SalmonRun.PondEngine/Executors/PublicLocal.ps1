<#
.SYNOPSIS
    Public local executor for the salmon-run PondEngine.

.DESCRIPTION
    This is the default executor for the public salmon-run package. It runs
    in-process, accepts a lane of plan files, and writes the completion
    sentinel. It is intended as an integration point: users can replace or
    extend it to call their own local agent CLI, while the PondEngine handles
    queueing, routing, and transitions.

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

    [Parameter(Mandatory, ValueFromRemainingArguments=$true)]
    [string[]]$PlanFiles
)

$ErrorActionPreference = 'Stop'

try {
    if (-not (Test-Path -LiteralPath $LanePath)) {
        throw "Lane path not found: $LanePath"
    }

    $log = @()
    $log += "[$(Get-Date -Format 'o')] Local executor started for role '$Role'"
    $log += "Lane: $LanePath"
    $log += "Repo: $RepoDir"
    $log += "Plans: $($PlanFiles -join ', ')"

    foreach ($plan in $PlanFiles) {
        $planName = Split-Path -Leaf $plan
        $planPath = Join-Path $LanePath $planName
        if (-not (Test-Path -LiteralPath $planPath)) { continue }

        $content = Get-Content -LiteralPath $planPath -Raw

        # Mark the plan as worked on by this role.
        if ($content -notmatch '(?im)^\*\*Agent\*\*:') {
            $content = $content + "`n`n**Agent**: $Role`n"
        }

        # Coder role records a minimal implementation note; reviewer/QA/auditor
        # can extend this block in later ponds.
        if ($Role -eq 'coder' -and $content -notmatch '(?im)^\*\*Implementation\*\*:') {
            $content = $content + "`n**Implementation**: completed by public local executor`n"
        }

        # Reviewer checks that the coder left implementation evidence.
        if ($Role -eq 'reviewer') {
            if ($content -notmatch '(?im)^\*\*Implementation\*\*:') {
                throw "Plan '$planName' is missing **Implementation** evidence"
            }
            if ($content -notmatch '(?im)^\*\*Reviewed\*\*:') {
                $content = $content + "`n**Reviewed**: passed by public local reviewer`n"
            }
        }

        # Auditor runs a lightweight best-practice/secret scan on the plan.
        if ($Role -eq 'auditor') {
            if ($content -notmatch '(?im)^\*\*Reviewed\*\*:') {
                throw "Plan '$planName' is missing **Reviewed** evidence"
            }
            $secretPattern = "(?im)(api[_-]?key|apikey|token|secret|password)\s*[:=]\s*(`"(?:[^`"`r`n]{4,})`"|'(?:[^'`r`n]{4,})')"
            if ($content -match $secretPattern) {
                throw "Plan '$planName' appears to contain a credential value"
            }
            if ($content -notmatch '(?im)^\*\*Audit\*\*:') {
                $content = $content + "`n**Audit**: passed by public local auditor`n"
            }
        }

        # QA performs a final evidence check before the plan reaches Complete.
        if ($Role -eq 'qa') {
            if ($content -notmatch '(?im)^\*\*Implementation\*\*:') {
                throw "Plan '$planName' is missing **Implementation** evidence"
            }
            if ($content -notmatch '(?im)^\*\*Reviewed\*\*:') {
                throw "Plan '$planName' is missing **Reviewed** evidence"
            }
            if ($content -notmatch '(?im)^\*\*Audit\*\*:') {
                throw "Plan '$planName' is missing **Audit** evidence"
            }
            if ($content -notmatch '(?im)^\*\*QA\*\*:') {
                $content = $content + "`n**QA**: passed by public local qa`n"
            }
        }

        $content | Set-Content -LiteralPath $planPath -Encoding utf8 -NoNewline
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
