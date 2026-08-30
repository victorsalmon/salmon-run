#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $moduleRoot = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
    $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $moduleRoot 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
}

Describe 'Concept to complete project' -Tag 'PondEngine','E2E' {
    It 'prints, decomposes, verifies, and bundles a project in an isolated runtime' {
        $runtimeRoot = Join-Path $TestDrive 'runtime'
        $taskRoot = Join-Path $runtimeRoot 'Tasks'
        foreach ($queue in 'Intake','Code','Review','Audit','QA','Complete','Archive','Failed','Working','Project','ProjectReview','Paused','Feedback','Logs') {
            New-Item -ItemType Directory -Path (Join-Path $taskRoot $queue) -Force | Out-Null
        }
        $projectPath = New-SalmonProjectPlan -Concept 'Build a deterministic example feature with focused tests.' -ProjectId 'acceptance-example' -Sessions @('implementation') -AcceptanceCriteria @('The deterministic fixture completes its lifecycle.') -ValidationCommands @('pwsh -NoProfile -Command "exit 0"') -BehaviorRisks @('Queue state and typed attempt binding remain invariant.') -MutationCommand 'PublicLocal deterministic mutation canary' -EnvironmentPrerequisites @('PowerShell 7 and Pester 6') -TaskRoot $taskRoot
        Add-Content -LiteralPath $projectPath -Value "`n**Challenge**: Local"
        Start-PondEngine -RepoDir $runtimeRoot -TaskRoot $taskRoot -MaxIterations 8 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1

        $bundle = Join-Path $taskRoot 'Complete/acceptance-example'
        Join-Path $bundle 'project.md' | Should -Exist
        Join-Path $bundle 'manifest.json' | Should -Exist
        @(Get-ChildItem (Join-Path $bundle 'plans') -Filter '*.md') | Should -HaveCount 1
        $manifest = Get-Content (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
        $manifest.projectId | Should -Be 'acceptance-example'
        $manifest.milestones.qaPassed | Should -BeTrue
        $manifest.milestones.projectReviewPassed | Should -BeTrue
    }
}
