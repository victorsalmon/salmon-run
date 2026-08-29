function Test-PondExecutorVerdict {
    <#
    .SYNOPSIS
        Validates agent-authored evidence before an executor writes .complete.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Role,

        [Parameter(Mandatory)]
        [string[]]$PlanFiles
    )

    $contract = switch ($Role) {
        'coder'            { @{ Header = 'Implementation'; Pass = 'completed|passed' } }
        'reviewer'         { @{ Header = 'Reviewed'; Pass = 'passed|completed'; Decision = 'ReviewDecision' } }
        'auditor'          { @{ Header = 'Audit'; Pass = 'passed|completed'; Decision = 'AuditDecision' } }
        'qa'               { @{ Header = 'QA'; Pass = 'passed|completed'; Decision = 'QADecision' } }
        'project-reviewer' { @{ Header = 'ProjectReview'; Pass = 'passed|completed'; Decision = 'ProjectReviewDecision' } }
        'investigator'     { @{ Header = 'Investigated'; Pass = 'passed|completed'; Decision = 'InvestigatorDecision' } }
        default            { return $true }
    }

    foreach ($plan in $PlanFiles) {
        if (-not (Test-Path -LiteralPath $plan)) { return $false }
        $content = Get-Content -LiteralPath $plan -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) { return $false }

        if ($contract.Decision) {
            $decision = [regex]::Match($content, "(?im)^\*\*$($contract.Decision)\*\*:\s*(?<value>[^\r\n]+)")
            if ($decision.Success) {
                $value = $decision.Groups['value'].Value.Trim()
                if ($value -match '^(rework|fail(?:ed)?|reject(?:ed)?|blocked)\b') { return $false }
                if ($value -match '^pass(?:ed)?\b') { continue }
            }
        }

        $evidence = [regex]::Match($content, "(?im)^\*\*$($contract.Header)\*\*:\s*(?<value>[^\r\n]+)")
        if (-not $evidence.Success) {
            # Coding adapters historically return successfully after applying a
            # change even when the legacy evidence line was omitted. Preserve
            # that compatibility, but never accept an explicit failed line.
            if ($Role -eq 'coder') { continue }
            return $false
        }
        $value = $evidence.Groups['value'].Value.Trim()
        if ($value -match '^(failed|rework|rejected|blocked)\b') { return $false }
        if ($value -notmatch "^($($contract.Pass))\b") { return $false }
    }
    return $true
}
