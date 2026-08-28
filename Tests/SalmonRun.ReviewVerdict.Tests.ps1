#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $script:VerdictHelper = Join-Path $script:RepoRoot 'Modules/SalmonRun.PondEngine/Executors/PondVerdict.ps1'
}

Describe 'Executor verdict contract' -Tag 'PondEngine','Regression-Only' {
    It 'ships a shared verdict validator used by every external executor' {
        $script:VerdictHelper | Should -Exist
        foreach ($name in 'Opencode.ps1','Codex.ps1','Devin.ps1','Dsh.ps1') {
            Get-Content (Join-Path $script:RepoRoot "Modules/SalmonRun.PondEngine/Executors/$name") -Raw |
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
}

