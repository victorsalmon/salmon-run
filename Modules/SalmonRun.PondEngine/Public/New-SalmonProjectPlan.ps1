function New-SalmonProjectPlan {
    <#
    .SYNOPSIS
        Prints a project concept into the Salmon Run Project queue.
    .DESCRIPTION
        Creates a structured project plan that the Project pond can decompose
        deterministically. The generated session templates target 70,000 coding
        tokens and the Project pond enforces the hard 100,000-token ceiling.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Concept,

        [string]$ProjectId,

        [string[]]$Sessions = @(),

        [string[]]$AcceptanceCriteria = @(),

        [string[]]$ValidationCommands = @(),

        [string[]]$BehaviorRisks = @(),

        [string[]]$RequiredTestLayers = @('focused regression', 'full regression', 'property/stateful/integration/E2E as applicable'),

        [string]$MutationCommand = '',

        [string]$MutationScope = 'changed production code',

        [string[]]$EnvironmentPrerequisites = @(),

        [string]$ResolvedExecutionProfiles = 'Resolve from ~/.salmon/config.json at dispatch',

        [ValidateRange(1, 100000)]
        [int]$TargetImplementationTokens = 70000,

        [string]$TaskRoot = (Get-SalmonTaskRoot)
    )

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        $words = [regex]::Matches($Concept.ToLowerInvariant(), '[a-z0-9]+') |
            Select-Object -First 8 | ForEach-Object Value
        $ProjectId = ($words -join '-')
    }
    $ProjectId = ($ProjectId.ToLowerInvariant() -replace '[^a-z0-9-]+','-' -replace '-{2,}','-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { throw 'ProjectId could not be derived from the concept.' }

    if (@($Sessions).Count -eq 0) {
        $Sessions = @('architecture-and-contracts', 'implementation', 'verification-and-hardening')
    }
    $normalizedSessions = @($Sessions | ForEach-Object {
        $name = ($_.ToLowerInvariant() -replace '[^a-z0-9-]+','-' -replace '-{2,}','-').Trim('-')
        if (-not [string]::IsNullOrWhiteSpace($name)) { $name }
    } | Select-Object -Unique)
    if ($normalizedSessions.Count -eq 0) { throw 'At least one usable session name is required.' }

    $projectDir = Join-Path $TaskRoot 'Project'
    $null = New-Item -ItemType Directory -Path $projectDir -Force
    $fileName = "$(Get-Date -Format 'yyyy-MM-dd')-$ProjectId.md"
    $path = Join-Path $projectDir $fileName
    if (Test-Path -LiteralPath $path) { throw "Project plan already exists: $path" }

    $sessionLines = for ($i = 0; $i -lt $normalizedSessions.Count; $i++) {
        "- $($normalizedSessions[$i]): deliver the $($normalizedSessions[$i] -replace '-',' ') portion of the concept; estimate $TargetImplementationTokens tokens"
    }
    $totalEstimate = $TargetImplementationTokens * $normalizedSessions.Count
    $acceptanceLines = if ($AcceptanceCriteria.Count) { $AcceptanceCriteria | ForEach-Object { "- $_" } } else { @('- Every stated outcome is implemented and independently verifiable.') }
    $validationLines = if ($ValidationCommands.Count) { $ValidationCommands | ForEach-Object { "- ``$_``" } } else { @('- decision-required: Intake must record exact repository commands before Code dispatch.') }
    $riskLines = if ($BehaviorRisks.Count) { $BehaviorRisks | ForEach-Object { "- $_" } } else { @('- decision-required: Intake must inventory changed behaviors and invariants before Code dispatch.') }
    $testLayerLines = $RequiredTestLayers | ForEach-Object { "- $_" }
    $prerequisiteLines = if ($EnvironmentPrerequisites.Count) { $EnvironmentPrerequisites | ForEach-Object { "- $_" } } else { @('- None identified; Intake must confirm this before Code dispatch.') }
    $mutationValue = if ($MutationCommand) { $MutationCommand } else { 'decision-required: Intake must select or install changed-code mutation tooling.' }
    $content = @"
# Project Plan: $ProjectId
**Status**: ready
**Scope**: $Concept
**ProjectId**: $ProjectId
**Children**: $($normalizedSessions -join ', ')
**EstimatedImplementationTokens**: $totalEstimate
**SessionTokenCeiling**: 100000
**ResolvedExecutionProfiles**: $ResolvedExecutionProfiles

## Concept

$Concept

## Session Plans

$($sessionLines -join "`n")

## Acceptance Criteria

$($acceptanceLines -join "`n")

## Exact Validation Commands

$($validationLines -join "`n")

## Behavior and Invariant Risks

$($riskLines -join "`n")

## Required Test Layers

$($testLayerLines -join "`n")

## Mutation Contract

- Command: $mutationValue
- Scope: $MutationScope
- Gate: raw changed-code score >= 95%; no unresolved outcomes and no waivers.

## Environment Prerequisites

$($prerequisiteLines -join "`n")

## Dependencies

- Child order is recorded in **Children**; Intake must add external dependencies before Code dispatch.

## Project Acceptance

- Every child plan satisfies its acceptance criteria and focused tests.
- Review and audit decisions pass for every child.
- Project QA runs once after the complete child set is QA-ready.
- Final project review considers the integrated result and records remaining risks.
"@
    Set-Content -LiteralPath $path -Value $content -Encoding utf8 -NoNewline
    return $path
}
