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

    It 'uses the latest review evidence when historical attempts disagree' {
        . $script:VerdictHelper
        $plan = Join-Path $TestDrive 'review-history.md'
        "# Plan`n**Reviewed**: failed by test - old attempt failed`n**Reviewed**: passed by test" | Set-Content $plan -NoNewline
        Test-PondExecutorVerdict -Role reviewer -PlanFiles @($plan) | Should -BeTrue
    }

    It 'rejects when the latest review evidence fails after an earlier pass' {
        . $script:VerdictHelper
        $plan = Join-Path $TestDrive 'review-regression.md'
        "# Plan`n**Reviewed**: passed by test`n**Reviewed**: failed by test - current attempt failed" | Set-Content $plan -NoNewline
        Test-PondExecutorVerdict -Role reviewer -PlanFiles @($plan) | Should -BeFalse
    }

    It 'returns the canonical plan to Code with linked feedback' {
        $taskRoot = Join-Path $TestDrive 'Tasks'; $lane = Join-Path $taskRoot 'Working/review-lane'
        foreach ($path in $lane,(Join-Path $taskRoot 'Code'),(Join-Path $taskRoot 'Review')) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        $planName='2026-08-28-review-me.md'; $plan=Join-Path $lane $planName
        "# Plan`n**Status**: ready`n**Scope**: test`n**Reviewed**: failed by test - missing behavior" | Set-Content $plan -NoNewline
        $pond=Get-SalmonRunPonds|Where-Object Name -eq Review; $group=[PondGroup]::new();$group.Namespace='review-me';$group.StreamPath=$lane;$group.RepoPath=$TestDrive;$group.Files=@(Get-Item $plan)
        $context=[PondContext]::new();$context.TaskRoot=$taskRoot;$context.RepoDir=$TestDrive;$context.CurrentGroup=$group;$context.CurrentPond=$pond;$context.Success=$true
        $task=$pond.Tasks|Where-Object Name -eq Transition
        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $context | Out-Null
        $canonical=Join-Path $taskRoot "Code/$planName"; $canonical|Should -Exist; Join-Path $taskRoot "Review/$planName"|Should -Not -Exist
        $content=Get-Content $canonical -Raw
        $content | Should -Match '(?im)^\*\*Status\*\*:\s*ready$'
        $content | Should -Match '(?im)^\*\*Feedback\*\*:\s*Results/'
        $relative=([regex]::Match($content,'(?im)^\*\*Feedback\*\*:\s*(?<v>[^\r\n]+)')).Groups['v'].Value.Trim(); $sidecar=Join-Path (Split-Path $taskRoot -Parent) $relative
        $sidecar|Should -Exist; (Get-Content $sidecar -Raw|ConvertFrom-Json).reason|Should -Be 'missing behavior'
        @(Get-ChildItem (Join-Path $taskRoot 'Code') -Filter '*feedback*.md').Count|Should -Be 0
    }
}
