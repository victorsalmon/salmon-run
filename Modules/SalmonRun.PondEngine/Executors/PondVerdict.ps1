if (-not (Get-Command Get-PondGateVerdict -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../Private/PondGateVerdict.ps1')
}

function Test-PondExecutorVerdict {
    <#
    .SYNOPSIS
        Validates agent-authored evidence before an executor writes .complete.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string[]]$PlanFiles
    )

    $contract = switch ($Role) {
        'coder'            { @{ Header = 'Implementation'; Decision = $null } }
        'reviewer'         { @{ Header = 'Reviewed'; Decision = 'ReviewDecision' } }
        'auditor'          { @{ Header = 'Audit'; Decision = 'AuditDecision' } }
        'qa'               { @{ Header = 'QA'; Decision = 'QADecision' } }
        'project-reviewer' { @{ Header = 'ProjectReview'; Decision = 'ProjectReviewDecision' } }
        'investigator'     { @{ Header = 'Investigated'; Decision = 'InvestigatorDecision' } }
        default            { return $true }
    }

    foreach ($plan in $PlanFiles) {
        if (-not (Test-Path -LiteralPath $plan)) { return $false }
        $content = Get-Content -LiteralPath $plan -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) { return $false }

        $verdict = Get-PondGateVerdict -Content $content -DecisionHeader $contract.Decision -EvidenceHeader $contract.Header
        if (-not $verdict.Found) {
            # Preserve coding-adapter compatibility while all providers migrate
            # to the structured result contract.
            if ($Role -eq 'coder') { continue }
            return $false
        }
        if ($verdict.Failed -or -not $verdict.Passed) { return $false }
    }
    return $true
}