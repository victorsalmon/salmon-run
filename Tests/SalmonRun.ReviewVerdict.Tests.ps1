#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $moduleRoot = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
    $script:VerdictHelper = Join-Path $moduleRoot 'SalmonRun.PondEngine/Executors/PondVerdict.ps1'
    $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $moduleRoot 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
}

Describe 'Executor verdict contract' -Tag 'PondEngine','Regression-Only' {
    It 'ships a shared verdict validator used by every external executor' {
        $script:VerdictHelper | Should -Exist
        foreach ($name in 'Opencode.ps1','Codex.ps1','Devin.ps1','Dsh.ps1') {
            Get-Content (Join-Path (Split-Path $script:VerdictHelper -Parent) $name) -Raw |
                Should -Match 'Test-PondExecutorVerdict'
        }
    }

    It 'rejects a failed review even when the provider process exited zero' {
        . $script:VerdictHelper
        $plan = Join-Path $TestDrive 'review.md'
        "# Plan`n**Reviewed**: failed by test - implementation missing" | Set-Content $plan -NoNewline
        Test-PondExecutorVerdict -Role reviewer -PlanFiles @($plan) | Should -BeFalse
    }

    It 'requires an explicit passing review verdict' {
        . $script:VerdictHelper
        $plan = Join-Path $TestDrive 'review-pass.md'
        "# Plan`n**ReviewDecision**: pass`n**Reviewed**: passed by test" | Set-Content $plan -NoNewline
        Test-PondExecutorVerdict -Role reviewer -PlanFiles @($plan) | Should -BeTrue
    }

    It 'blocks a rejected Review plan and creates a Code feedback plan' {
        $taskRoot = Join-Path $TestDrive 'Tasks'
        $lane = Join-Path $taskRoot 'Working/review-lane'
        foreach ($path in $lane,(Join-Path $taskRoot 'Code'),(Join-Path $taskRoot 'Review')) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $planName = '2026-08-28-review-me.md'
        $plan = Join-Path $lane $planName
        "# Plan`n**Status**: ready`n**Scope**: test`n**Reviewed**: failed by test - missing behavior" | Set-Content $plan -NoNewline
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Review
        $group = [PondGroup]::new(); $group.Namespace='review-me'; $group.StreamPath=$lane; $group.RepoPath=$TestDrive; $group.Files=@(Get-Item $plan)
        $context = [PondContext]::new(); $context.TaskRoot=$taskRoot; $context.RepoDir=$TestDrive; $context.CurrentGroup=$group; $context.CurrentPond=$pond; $context.Success=$true
        $task = $pond.Tasks | Where-Object Name -eq Transition
        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $context | Out-Null

        $blockedPlan = Join-Path $taskRoot "Review/$planName"
        $feedbackName = '2026-08-28-review-me-feedback1.md'
        $feedbackPlan = Join-Path $taskRoot "Code/$feedbackName"

        $blockedPlan | Should -Exist
        $feedbackPlan | Should -Exist
        Join-Path $taskRoot "Code/$planName" | Should -Not -Exist

        $blockedContent = Get-Content $blockedPlan -Raw
        $blockedContent | Should -Match '(?im)^\*\*Blocked\*\*: true$'
        $blockedContent | Should -Match '(?im)^\*\*BlockedBy\*\*: Review$'
        $blockedContent | Should -Match '(?im)^\*\*BlockedReason\*\*: missing behavior$'
        $blockedContent | Should -Match "(?im)^\*\*WaitingFor\*\*: $([regex]::Escape($feedbackName))"
        $blockedContent | Should -Match '(?im)^\*\*Status\*\*: blocked$'

        $feedbackContent = Get-Content $feedbackPlan -Raw
        $feedbackContent | Should -Match '# Feedback plan: 2026-08-28-review-me'
        $feedbackContent | Should -Match '\*\*Status\*\*: ready'
        $feedbackContent | Should -Match '\*\*PlanType\*\*: feedback'
        $feedbackContent | Should -Match '\*\*FailedStage\*\*: Review'
        $feedbackContent | Should -Match '\*\*Reviewed\*\*: failed by reviewer - missing behavior'
        $feedbackContent | Should -Match '## Feedback for Coder'
        $feedbackContent | Should -Match '\*\*Source\*\*: Review'
        $feedbackContent | Should -Match '\*\*Verdict\*\*: failed'
    }
}
