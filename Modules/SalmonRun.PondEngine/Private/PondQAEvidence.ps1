function New-PondQAEvidenceResult {
    param([bool]$Passed, [bool]$DecisionRequired, [string]$Error, [string]$Sha256 = '', [string]$Path = '')
    [pscustomobject]@{ Passed = $Passed; DecisionRequired = $DecisionRequired; Error = $Error; Sha256 = $Sha256; Path = $Path }
}

function Test-PondQAEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$RepoDir
    )

    if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
        return New-PondQAEvidenceResult $false $false 'QA plan file is missing.'
    }
    $content = Get-Content -LiteralPath $PlanPath -Raw
    if ($content -match '(?im)^\*\*MutationTooling\*\*:\s*unavailable\s*$') {
        return New-PondQAEvidenceResult $false $true 'Required changed-code mutation tooling is unavailable; a human decision is required in Intake.'
    }
    if ($content -notmatch '(?im)^\*\*QAEvidence\*\*:\s*(?<value>[^\r\n]+)') {
        return New-PondQAEvidenceResult $false $false 'QA pass requires a **QAEvidence** relative path.'
    }

    $relative = $Matches.value.Trim().Trim('"', "'")
    if ([IO.Path]::IsPathRooted($relative)) {
        return New-PondQAEvidenceResult $false $false 'QAEvidence must be a repository-relative path.'
    }
    try {
        $root = [IO.Path]::GetFullPath($RepoDir).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $evidencePath = [IO.Path]::GetFullPath((Join-Path $root $relative))
    } catch {
        return New-PondQAEvidenceResult $false $false "Invalid QAEvidence path: $($_.Exception.Message)"
    }
    if (-not ($evidencePath.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase))) {
        return New-PondQAEvidenceResult $false $false 'QAEvidence path escapes the target repository.'
    }
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        return New-PondQAEvidenceResult $false $false "QAEvidence artifact '$relative' does not exist."
    }

    try { $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop }
    catch { return New-PondQAEvidenceResult $false $false "QAEvidence is not valid JSON: $($_.Exception.Message)" }

    $requiredTop = @('schemaVersion','decision','repository','commit','behaviorInventory','commands','mutation','waivers')
    foreach ($field in $requiredTop) {
        if (-not $evidence.PSObject.Properties[$field]) {
            return New-PondQAEvidenceResult $false $false "QAEvidence is missing required field '$field'."
        }
    }
    if ([int]$evidence.schemaVersion -ne 1 -or [string]$evidence.decision -ne 'pass') {
        return New-PondQAEvidenceResult $false $false 'QAEvidence must use schemaVersion 1 and decision pass.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$evidence.commit)) {
        return New-PondQAEvidenceResult $false $false 'QAEvidence must bind to a source commit.'
    }
    if (Test-Path -LiteralPath (Join-Path $root '.git')) {
        $currentCommit = (& git -C $root rev-parse HEAD 2>$null) -as [string]
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentCommit)) {
            return New-PondQAEvidenceResult $false $false 'The target repository commit could not be resolved for QA evidence binding.'
        }
        if ([string]$evidence.commit -ne $currentCommit.Trim()) {
            return New-PondQAEvidenceResult $false $false 'QAEvidence is stale: its commit does not match the target repository HEAD.'
        }
    }
    if (@($evidence.waivers).Count -ne 0) {
        return New-PondQAEvidenceResult $false $false 'Mutation waivers are not permitted.'
    }

    $inventory = $evidence.behaviorInventory
    if ([int]$inventory.total -le 0 -or [int]$inventory.mapped -ne [int]$inventory.total -or @($inventory.unmapped).Count -ne 0) {
        return New-PondQAEvidenceResult $false $false 'The behavior inventory must map every discovered behavior and invariant.'
    }
    $commands = @($evidence.commands)
    foreach ($required in @('audit-checks','full-regression','mutation')) {
        $command = $commands | Where-Object name -EQ $required | Select-Object -First 1
        if (-not $command -or [int]$command.exitCode -ne 0) {
            return New-PondQAEvidenceResult $false $false "QAEvidence command '$required' is missing or did not exit 0."
        }
    }
    if (@($commands | Where-Object { [int]$_.exitCode -ne 0 }).Count -gt 0) {
        return New-PondQAEvidenceResult $false $false 'Every recorded QA command must exit 0.'
    }

    $mutation = $evidence.mutation
    foreach ($field in @('killed','survived','noCoverage','timeout','compileError','equivalent','score','equivalentDispositions')) {
        if (-not $mutation.PSObject.Properties[$field]) {
            return New-PondQAEvidenceResult $false $false "Mutation evidence is missing '$field'."
        }
    }
    $unresolved = [int]$mutation.survived + [int]$mutation.noCoverage + [int]$mutation.timeout + [int]$mutation.compileError
    if ($unresolved -ne 0) {
        return New-PondQAEvidenceResult $false $false 'Changed-code mutation score must be at least 95%; every survivor, no-coverage result, timeout, and compile error must be resolved.'
    }
    $equivalent = [int]$mutation.equivalent
    $dispositions = @($mutation.equivalentDispositions)
    if ($dispositions.Count -ne $equivalent) {
        return New-PondQAEvidenceResult $false $false 'Every equivalent mutant must have an explicit disposition.'
    }
    foreach ($item in $dispositions) {
        if ($item.equivalent -ne $true -or [string]::IsNullOrWhiteSpace([string]$item.proof) -or [string]::IsNullOrWhiteSpace([string]$item.resolution)) {
            return New-PondQAEvidenceResult $false $false 'Equivalent-mutant dispositions require proof and a resolution.'
        }
    }
    $denominator = [int]$mutation.killed + $unresolved + $equivalent
    $rawScore = if ($denominator -eq 0) { 0.0 } else { 100.0 * [int]$mutation.killed / $denominator }
    if ($rawScore -lt 95.0 -or [double]$mutation.score -lt 95.0 -or [math]::Abs([double]$mutation.score - $rawScore) -gt 0.05) {
        return New-PondQAEvidenceResult $false $false "Raw changed-code mutation score must be at least 95% (computed $([math]::Round($rawScore, 2))%)."
    }

    $hash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
    return New-PondQAEvidenceResult $true $false $null $hash $relative
}
