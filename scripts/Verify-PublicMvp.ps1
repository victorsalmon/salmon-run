#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Focused')]
param(
    [Parameter(ParameterSetName='Focused')][switch]$Focused,
    [Parameter(ParameterSetName='FullSuite')][switch]$FullSuite,
    [Parameter(ParameterSetName='Documentation')][switch]$Documentation,
    [Parameter(ParameterSetName='LocalCanary')][switch]$LocalCanary,
    [Parameter(ParameterSetName='SyncParity')][switch]$SyncParity,
    [Parameter(ParameterSetName='Mutation')][switch]$Mutation,
    [Parameter(ParameterSetName='OpenCodeCanary')][switch]$OpenCodeCanary,
    [Parameter(ParameterSetName='Soak')][switch]$Soak,
    [double]$SoakHours = 4,
    [string]$PrivateRepo = $env:SALMON_PRIVATE_REPO
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

function Invoke-GreenPester([string[]]$Paths) {
    $result = Invoke-Pester -Path $Paths -Output Normal -PassThru
    if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) { throw "Pester failed: $($result.FailedCount) tests, $($result.FailedContainersCount) containers." }
}

switch ($PSCmdlet.ParameterSetName) {
    'Focused' {
        Invoke-GreenPester @(
            (Join-Path $repo 'Tests/SalmonRun.PublicMvp.Tests.ps1'),
            (Join-Path $repo 'Tests/SalmonRun.PondEngine.Feedback.Tests.ps1'),
            (Join-Path $repo 'Tests/SalmonRun.Sync.Tests.ps1'),
            (Join-Path $repo 'Tests/SalmonRun.PondEngine.Mutation.Tests.ps1')
        )
        'SALMON_MVP_FOCUSED_PASS'
    }
    'FullSuite' {
        Invoke-GreenPester @((Join-Path $repo 'Tests'))
        'SALMON_MVP_FULL_SUITE_PASS'
    }
    'Documentation' {
        $moduleRoot = Join-Path $repo 'Modules'
        $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
        Import-Module (Join-Path $moduleRoot 'SalmonRun.AQE/SalmonRun.AQE.psd1') -Force
        $lint = Invoke-SalmonRunDocLint -RepoDir $repo
        if ($lint.PSObject.Properties['Passed'] -and -not $lint.Passed) { throw 'Documentation lint failed.' }
        & (Join-Path $repo 'scripts/Invoke-LeakCheck.ps1') -SearchRoot $repo
        if ($LASTEXITCODE -ne 0) { throw 'Public leak check failed.' }
        'SALMON_MVP_DOCUMENTATION_PASS'
    }
    'LocalCanary' {
        Invoke-GreenPester @((Join-Path $repo 'Tests/SalmonRun.OrchestratorE2E.Tests.ps1'))
        'SALMON_MVP_LOCAL_CANARY_PASS'
    }
    'SyncParity' {
        if ([string]::IsNullOrWhiteSpace($PrivateRepo)) { throw 'Private consumer path is required via -PrivateRepo or SALMON_PRIVATE_REPO.' }
        & (Join-Path $repo 'scripts/Sync-ToPrivate.ps1') -PublicRepo $repo -PrivateRepo $PrivateRepo -Verify
        $privateManifest = Join-Path $PrivateRepo 'Orchestrator/Modules/SalmonRun.PondEngine/SalmonRun.PondEngine.psd1'
        if (-not (Test-Path -LiteralPath $privateManifest)) { throw 'Synchronized private PondEngine manifest is missing.' }
        $privateModules = Join-Path $PrivateRepo 'Orchestrator/Modules'
        $probe = "`$env:PSModulePath='$($privateModules.Replace("'","''"))'+[IO.Path]::PathSeparator+`$env:PSModulePath; Import-Module '$($privateManifest.Replace("'","''"))' -Force; if((Get-SalmonRunPonds).Count -lt 1){exit 1}"
        & pwsh -NoProfile -NonInteractive -Command $probe
        if ($LASTEXITCODE -ne 0) { throw 'Synchronized private consumer could not load and run the PondEngine.' }
        'SALMON_MVP_SYNC_PARITY_PASS'
    }
    'Mutation' {
        $result = & (Join-Path $repo 'Tools/QA/powershell-property-testing/Invoke-PondEngineMutationAnalysis.ps1') -RepoRoot $repo
        if ($LASTEXITCODE -ne 0 -or -not $result.Passed) { throw 'Changed-code mutation analysis failed.' }
        $score = if ($result.Total) { 100.0 * $result.Killed / $result.Total } else { 0.0 }
        if ($score -lt 95.0 -or $result.Survived -ne 0) { throw "Changed-code mutation score $score is below 95% or has survivors." }
        "SALMON_MVP_MUTATION_PASS score=$score killed=$($result.Killed) total=$($result.Total)"
    }
    'OpenCodeCanary' {
        if ($env:SALMON_RUN_OPENCODE_LIVE -ne '1') { throw 'Set SALMON_RUN_OPENCODE_LIVE=1 to authorize the real OpenCode Go canary.' }
        Invoke-GreenPester @(
            (Join-Path $repo 'Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1'),
            (Join-Path $repo 'Tests/SalmonRun.PondEngine.OpenCode.Lifecycle.Tests.ps1')
        )
        'SALMON_MVP_OPENCODE_CANARY_PASS'
    }
    'Soak' {
        & (Join-Path $repo 'scripts/Invoke-PublicLocalSoak.ps1') -RepoRoot $repo -Hours $SoakHours
        if ($LASTEXITCODE -ne 0) { throw 'PublicLocal soak failed.' }
        'SALMON_MVP_SOAK_PASS'
    }
}
