[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
)

$ErrorActionPreference = 'Stop'
$testFiles = @(
    (Join-Path $RepoRoot 'Tests/SalmonRun.ProjectPlanning.Tests.ps1'),
    (Join-Path $RepoRoot 'Tests/SalmonRun.ReviewVerdict.Tests.ps1'),
    (Join-Path $RepoRoot 'Tests/SalmonRun.ProjectLifecycle.Tests.ps1'),
    (Join-Path $RepoRoot 'Tests/SalmonRun.PondScheduling.Tests.ps1')
    (Join-Path $RepoRoot 'Tests/SalmonRun.PublicMvp.Tests.ps1')
)
$mutants = @(
    @{ Id='Planning-OverBudget'; File='SalmonRun.PondEngine/Private/PondTasks/Invoke-PondTaskPlanProject.ps1'; From='$targetTokens = [math]::Min([math]::Max($targetTokens, 1), 100000)'; To='$targetTokens = [math]::Min([math]::Max($targetTokens, 1), 100001)' },
    @{ Id='Review-FailedAccepted'; File='SalmonRun.PondEngine/Executors/PondVerdict.ps1'; From='if ($verdict.Failed -or -not $verdict.Passed) { return $false }'; To='if ($verdict.Failed -or -not $verdict.Passed) { return $true }' },
    @{ Id='QA-BatchBypass'; File='SalmonRun.PondEngine/Public/Get-SalmonRunPonds.ps1'; From="-EvidenceGate 'project-qa-ready'"; To="-EvidenceGate 'qa-ready'" },
    @{ Id='QA-MembershipInverted'; File='SalmonRun.PondEngine/Private/PondTasks/Get-PondProjectState.ps1'; From='$locations[$_] -ne ''QA'''; To='$locations[$_] -eq ''QA''' },
    @{ Id='ParallelCount-Bypass'; File='SalmonRun.PondEngine/Private/Select-PondGroups.ps1'; From='$limit = [math]::Min($limit, $Pond.Operators.ParallelCount)'; To='$limit = $limit' },
    @{ Id='Bundle-ProjectName'; File='SalmonRun.PondEngine/Private/PondTasks/Get-PondProjectState.ps1'; From='$projectDest = Join-Path $bundle ''project.md'''; To='$projectDest = Join-Path $bundle ''project-mutant.md''' },
    @{ Id='Override-Confirmation-Bypass'; File='SalmonRun.PondEngine/Private/Executor/PondExecutionSettings.ps1'; From='if ($overrides.Values.Count -gt 0 -and -not $overrides.Confirmed) {'; To='if ($overrides.Values.Count -gt 0 -and $overrides.Confirmed) {' },
    @{ Id='Cost-Ceiling-Inverted'; File='SalmonRun.PondEngine/Private/Executor/PondExecutionSettings.ps1'; From='if ($ceiling -gt 0 -and $profile.CostWithThinking -gt $ceiling) {'; To='if ($ceiling -gt 0 -and $profile.CostWithThinking -lt $ceiling) {' },
    @{ Id='Mutation-Threshold-Lowered'; File='SalmonRun.PondEngine/Private/PondQAEvidence.ps1'; From='if ($rawScore -lt 95.0 -or [double]$mutation.score -lt 95.0'; To='if ($rawScore -lt 94.0 -or [double]$mutation.score -lt 94.0' },
    @{ Id='Mutation-Survivor-Bypass'; File='SalmonRun.PondEngine/Private/PondQAEvidence.ps1'; From='if ($unresolved -ne 0) {'; To='if ($unresolved -lt 0) {' },
    @{ Id='Mutation-Waiver-Bypass'; File='SalmonRun.PondEngine/Private/PondQAEvidence.ps1'; From='if (@($evidence.waivers).Count -ne 0) {'; To='if (@($evidence.waivers).Count -lt 0) {' },
    @{ Id='Evidence-Path-Containment-Inverted'; File='SalmonRun.PondEngine/Private/PondQAEvidence.ps1'; From='if (-not ($evidencePath.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase))) {'; To='if ($evidencePath.StartsWith("$root$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {' },
    @{ Id='Commit-Binding-Bypass'; File='SalmonRun.PondEngine/Private/PondQAEvidence.ps1'; From='if ([string]$evidence.commit -ne $currentCommit.Trim()) {'; To='if ($false -and [string]$evidence.commit -ne $currentCommit.Trim()) {' }
)

function Invoke-MutationOracle {
    param([string]$ModuleRoot)
    $saved = $env:PONDENGINE_MUTATION_MODULE_ROOT
    $env:PONDENGINE_MUTATION_MODULE_ROOT = $ModuleRoot
    try {
        $quotedTests = ($testFiles | ForEach-Object { "'" + ($_ -replace "'","''") + "'" }) -join ','
        $command = "`$r=Invoke-Pester -Path @($quotedTests) -Output None -PassThru; if(`$r.FailedCount -gt 0 -or `$r.FailedContainersCount -gt 0){exit 1}else{exit 0}"
        & pwsh -NoProfile -NonInteractive -Command $command | Out-Null
        return $LASTEXITCODE
    } finally {
        if ($null -ne $saved) { $env:PONDENGINE_MUTATION_MODULE_ROOT = $saved } else { Remove-Item Env:\PONDENGINE_MUTATION_MODULE_ROOT -ErrorAction SilentlyContinue }
    }
}

$base = Join-Path ([IO.Path]::GetTempPath()) "SalmonRun-PondMutation-$([guid]::NewGuid().ToString('N'))"
$modulesSource = Join-Path $RepoRoot 'Modules'
$killed = 0
$results = @()
try {
    foreach ($mutant in $mutants) {
        $root = Join-Path $base $mutant.Id
        $moduleRoot = Join-Path $root 'Modules'
        Copy-Item -LiteralPath $modulesSource -Destination $moduleRoot -Recurse -Force
        $sourcePath = Join-Path $moduleRoot $mutant.File
        $content = [IO.File]::ReadAllText($sourcePath)
        if (-not $content.Contains($mutant.From)) { throw "Mutation pattern missing: $($mutant.Id)" }
        [IO.File]::WriteAllText($sourcePath, $content.Replace($mutant.From,$mutant.To), [Text.UTF8Encoding]::new($false))
        $exitCode = Invoke-MutationOracle -ModuleRoot $moduleRoot
        $isKilled = $exitCode -ne 0
        if ($isKilled) { $killed++ }
        $results += [pscustomobject]@{ Id=$mutant.Id; Killed=$isKilled }
        Write-Host "MUTANT $($mutant.Id) killed=$isKilled"
    }
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
$passed = $killed -eq $mutants.Count
[pscustomobject]@{ Total=$mutants.Count; Killed=$killed; Survived=($mutants.Count-$killed); Passed=$passed; Results=$results }
if (-not $passed) { exit 1 }
