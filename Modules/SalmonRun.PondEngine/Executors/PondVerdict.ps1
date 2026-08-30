if (-not (Get-Command Get-PondGateVerdict -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../Private/PondGateVerdict.ps1')
}
if (-not (Get-Command Get-RolePondLogMap -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'RolePrompts.ps1')
}

function Write-RolePondLogEntry {
    <#
    .SYNOPSIS
        Appends the canonical PondLog action for the current role when the
        executor is about to write .complete. This makes the evidence gate
        resilient even if the external agent only wrote the legacy header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string[]]$PlanFiles,
        [string]$Provider = 'unknown',
        [string]$Model = 'default'
    )

    if (-not (Get-Command Add-PlanPondLog -ErrorAction SilentlyContinue)) {
        $moduleBase = Split-Path -Path $PSScriptRoot -Parent
        $planLogPath = Join-Path $moduleBase 'Public' 'PlanLog.ps1'
        if (Test-Path -LiteralPath $planLogPath) { . $planLogPath }
    }

    $logMap = Get-RolePondLogMap -Role $Role
    $agent = if ($Model -and $Model.StartsWith("$Provider/", [System.StringComparison]::OrdinalIgnoreCase)) { $Model } else { "$Provider/$Model" }

    foreach ($plan in $PlanFiles) {
        try {
            $null = Add-PlanPondLog -PlanPath $plan -Entry @{
                pond   = $logMap.Pond
                role   = $Role
                action = $logMap.Action
                detail = "completed by $agent"
                agent  = $agent
            } -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "Write-RolePondLogEntry: failed to append PondLog for $Role on '$plan': $_"
        }
    }
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
        if (-not $verdict.Found) { return $false }
        if ($verdict.Failed -or -not $verdict.Passed) { return $false }
    }
    return $true
}