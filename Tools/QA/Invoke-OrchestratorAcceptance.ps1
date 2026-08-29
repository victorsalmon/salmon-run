[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PlanningBudget','PlanningContent','ReviewVerdict','ReviewFeedback','ProjectQaBatch','ProjectCompletion','Parallelism','Recovery','EndToEnd','Mutation','Full','LiveQueue')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$isolatedHome = Join-Path ([IO.Path]::GetTempPath()) "SalmonRun-Acceptance-$([guid]::NewGuid().ToString('N'))"
$savedHome = $env:SALMON_RUN_HOME
$savedRepoRoot = $env:REPO_ROOT
$env:SALMON_RUN_HOME = $isolatedHome
$env:REPO_ROOT = $repoRoot

function Invoke-AcceptanceTests {
    param([string[]]$Path, [string]$Marker, [string]$FullNameFilter='')
    $parameters = @{ Path=$Path; PassThru=$true; Output='Normal' }
    if ($FullNameFilter) { $parameters.FullNameFilter = $FullNameFilter }
    $result = Invoke-Pester @parameters
    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
        throw "Acceptance test failure: failed=$($result.FailedCount) containers=$($result.FailedContainersCount)"
    }
    Write-Output $Marker
}

try {
    switch ($Mode) {
        'PlanningBudget'    { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.ProjectPlanning.Tests.ps1')) 'PLANNING_BUDGET_OK' }
        'PlanningContent'   { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.ProjectPlanning.Tests.ps1')) 'PLANNING_CONTENT_OK' }
        'ReviewVerdict'     { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.ReviewVerdict.Tests.ps1')) 'REVIEW_VERDICT_OK' }
        'ReviewFeedback'    { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.ReviewVerdict.Tests.ps1')) 'REVIEW_FEEDBACK_OK' }
        'ProjectQaBatch'    { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.ProjectLifecycle.Tests.ps1')) 'PROJECT_QA_BATCH_OK' }
        'ProjectCompletion' { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.ProjectLifecycle.Tests.ps1')) 'PROJECT_COMPLETION_OK' }
        'Parallelism'       { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.PondScheduling.Tests.ps1')) 'PARALLELISM_OK' }
        'Recovery'          { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.PondScheduling.Tests.ps1')) 'RECOVERY_OK' }
        'EndToEnd'          { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests/SalmonRun.OrchestratorE2E.Tests.ps1')) 'ORCHESTRATOR_E2E_OK' }
        'Mutation' {
            $mutationOutput = @(& (Join-Path $repoRoot 'Tools/QA/powershell-property-testing/Invoke-PondEngineMutationAnalysis.ps1') -RepoRoot $repoRoot)
            $mutation = @($mutationOutput | Where-Object { $_.PSObject.Properties['Passed'] }) | Select-Object -Last 1
            if (-not $mutation -or -not $mutation.Passed) { throw 'PondEngine mutation analysis failed.' }
            Write-Output 'ORCHESTRATOR_MUTATION_OK'
        }
        'Full' { Invoke-AcceptanceTests @((Join-Path $repoRoot 'Tests')) 'SALMON_RUN_FULL_ACCEPTANCE_OK' }
        'LiveQueue' {
            $reportPath = Join-Path $repoRoot 'docs/live-queue-verification.json'
            if (-not (Test-Path -LiteralPath $reportPath)) { throw 'Live queue verification report is missing.' }
            $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
            if (-not $report.preservedAllPlans -or -not $report.actionableState -or ([datetime]::UtcNow - [datetime]$report.verifiedAt).TotalHours -gt 24) {
                throw 'Live queue verification is stale or failed.'
            }
            Write-Output 'LIVE_QUEUE_OK'
        }
    }
} finally {
    if ($null -ne $savedHome) { $env:SALMON_RUN_HOME=$savedHome } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $savedRepoRoot) { $env:REPO_ROOT=$savedRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $isolatedHome) { Remove-Item -LiteralPath $isolatedHome -Recurse -Force -ErrorAction SilentlyContinue }
}
