function Invoke-PondTaskPlanProject {
    <#
    .SYNOPSIS
        Decomposes a Project plan into child Code plans and a ProjectReview plan.
    .DESCRIPTION
        Reads the project contract, creates substantive child plans under
        Tasks/Code, and writes exact child membership back to the parent. Every
        child carries an implementation estimate no greater than 100,000 tokens.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Pond]$Pond,

        [Parameter(Mandatory)]
        [PondTask]$Task,

        [Parameter(Mandatory)]
        [PondContext]$Context
    )

    $group = $Context.CurrentGroup
    if (-not $group) { $Context.Continue = $false; return $Context }

    $lanePath = $group.StreamPath
    if ([string]::IsNullOrWhiteSpace($lanePath)) {
        $Context.Continue = $false
        return $Context
    }

    $files = @(Get-ChildItem "$lanePath/*.md" -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { $Context.Success = $false; return $Context }

    foreach ($file in $files) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) { continue }

        # Concept-only prints deliberately carry decision-required markers.
        # Keep those children interactive until Intake supplies exact commands,
        # risks, mutation tooling, prerequisites, and any human choices.
        $destinationPond = if ($content -match '(?i)decision-required') { 'Intake' } else { 'Code' }
        $childDir = Join-Path $Context.TaskRoot $destinationPond
        $null = New-Item -ItemType Directory -Path $childDir -Force -ErrorAction SilentlyContinue

        $parentChildStems = [System.Collections.Generic.List[string]]::new()

        # Determine child task names from the explicit contract. A concept-only
        # project gets a quality-first default decomposition rather than a
        # content-free `child` placeholder.
        $children = @()
        if ($content -match '(?im)^\*\*Children\*\*:\s*(?<value>[^\r\n]+)') {
            $children = @($Matches['value'].Trim() -split ',\s*' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if (@($children).Count -eq 0) {
            $children = @('architecture-and-contracts', 'implementation', 'verification-and-hardening')
        }

        $parentBase = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $parentNs = Get-PondFileNamespace -FileName $file.Name
        $projectIdMatch = [regex]::Match($content, '(?im)^\*\*ProjectId\*\*:\s*(?<value>[^\r\n]+)')
        $projectId = if ($projectIdMatch.Success) { $projectIdMatch.Groups['value'].Value.Trim() } else { $parentNs }
        $conceptMatch = [regex]::Match($content, '(?ims)^## Concept\s*\r?\n+(?<value>.*?)(?=^## |\z)')
        $concept = if ($conceptMatch.Success) { $conceptMatch.Groups['value'].Value.Trim() } else { $projectId }
        $targetMatch = [regex]::Match($content, '(?im)^\*\*SessionTargetTokens\*\*:\s*(?<value>\d+)')
        $targetTokens = if ($targetMatch.Success) { [int]$targetMatch.Groups['value'].Value } else { 70000 }
        $targetTokens = [math]::Min([math]::Max($targetTokens, 1), 100000)

        $childIndex = 0
        foreach ($child in $children) {
            $childIndex++
            $childSlug = ($child.ToLowerInvariant() -replace '[^a-z0-9-]+','-' -replace '-{2,}','-').Trim('-')
            if ([string]::IsNullOrWhiteSpace($childSlug)) { $childSlug = "session-$childIndex" }
            $childStem = "$parentBase-$childSlug-$childIndex"
            $childPath = Join-Path $childDir "$childStem.md"

            $childContent = @"
# Session Plan: $child
**Status**: ready
**Scope**: Implement the $child work package for $projectId
**Challenge**: Local
**ProjectId**: $projectId
**ParentPlan**: $parentBase
**EstimatedImplementationTokens**: $targetTokens
**ResolvedExecutionProfiles**: inherited from parent and resolved at dispatch

## Outcome

Deliver the $child portion of this project concept:

$concept

## Acceptance Criteria

- The work package is implemented in the target repository, not merely described.
- Focused regression tests cover the behavior changed by this work package.
- The implementation stays within this plan's declared scope and token ceiling.
- Review evidence records an explicit pass or rework decision and feedback artifact.

## Verification

- Intake must replace any decision-required parent fields with exact repository commands before this plan enters Code.
- Code runs focused regression tests for implementation safety.
- Audit reruns deterministic secret/docs/lint/static/build/focused-regression checks and AQE.
- QA runs the full regression and applicable property/stateful/integration/E2E layers.

## Behavior and Invariant Risks

- Inherit the parent inventory and narrow it to this work package before Code dispatch.

## Required Test Layers

- Code: focused regression and acceptance tests.
- QA: complete behavior inventory, full regression, property/stateful/integration/E2E as applicable.

## Mutation Contract

- Run the parent's changed-code mutation command over production code changed by this work package.
- Require a raw score of at least 95% with no unresolved outcomes or waivers.

## Environment Prerequisites

- Inherit and verify the parent prerequisites before dispatch.

## Dependencies

- Parent: $parentBase
"@

            $childContent | Set-Content -LiteralPath $childPath -Encoding utf8 -NoNewline
            $parentChildStems.Add($childStem)
        }

        # Update the parent plan with a DependsOn list so ProjectReview can gate.
        $dependsOn = ($parentChildStems | Select-Object -Unique) -join ', '
        if ($content -match '(?im)^\*\*DependsOn\*\*:[ \t]*[^\r\n]*') {
            $content = $content -replace '(?im)^\*\*DependsOn\*\*:[ \t]*[^\r\n]*', "**DependsOn**: $dependsOn"
        } else {
            $content = $content + "`n`n**DependsOn**: $dependsOn`n"
        }

        if ($content -match '(?im)^\*\*Status\*\*:\s*[^\r\n]+') {
            $content = $content -replace '(?im)^\*\*Status\*\*:\s*[^\r\n]+', "**Status**: ready"
        } else {
            $content = $content + "`n**Status**: ready`n"
        }
        if ($content -match '(?im)^\*\*ProjectId\*\*:\s*[^\r\n]+') {
            $content = $content -replace '(?im)^\*\*ProjectId\*\*:\s*[^\r\n]+', "**ProjectId**: $projectId"
        } else {
            $content = $content + "`n**ProjectId**: $projectId`n"
        }

        $content | Set-Content -LiteralPath $file.FullName -Encoding utf8 -NoNewline
    }

    $Context.Success = $true
    Write-Verbose "Invoke-PondTaskPlanProject: decomposed project '$($group.Namespace)'"
    return $Context
}
