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
    $content = @"
# Project Plan: $ProjectId
**Status**: ready
**Scope**: $Concept
**ProjectId**: $ProjectId
**Children**: $($normalizedSessions -join ', ')
**EstimatedImplementationTokens**: $totalEstimate
**SessionTokenCeiling**: 100000

## Concept

$Concept

## Session Plans

$($sessionLines -join "`n")

## Project Acceptance

- Every child plan satisfies its acceptance criteria and focused tests.
- Review and audit decisions pass for every child.
- Project QA runs once after the complete child set is QA-ready.
- Final project review considers the integrated result and records remaining risks.
"@
    Set-Content -LiteralPath $path -Value $content -Encoding utf8 -NoNewline
    return $path
}

