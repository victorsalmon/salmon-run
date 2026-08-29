#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

$__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
$env:PSModulePath = "$__RepoRoot\Modules$([System.IO.Path]::PathSeparator)$env:PSModulePath"
Remove-Module 'SalmonRun.PondEngine' -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $__RepoRoot 'Modules/SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force -ErrorAction Stop

InModuleScope 'SalmonRun.PondEngine' {
    BeforeAll {
        $script:SavedSALMON_RUN_HOME = $env:SALMON_RUN_HOME
        $script:TestSalmonHome = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'salmon-home') -Force
        $env:SALMON_RUN_HOME = $script:TestSalmonHome.FullName
    }

    AfterAll {
        $env:SALMON_RUN_HOME = $script:SavedSALMON_RUN_HOME
    }

    Describe 'Feedback-failure counter and Investigator spawn' -Tag 'PondEngine','Investigator','Regression' {
        It 'increments the counter when a failing Review plan produces feedback' {
            $taskRoot = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'investigate-review-root') -Force).FullName
            Set-PondFeedbackFailureCounter -Counter @{ count = 0; investigatorPending = $false; lastFailureAt = $null; lastInvestigatorAt = $null } -TaskRoot $taskRoot

            $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-reviewer-x-1') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Review') -Force
            $planName = '2026.08.28-review-fail.md'
            $plan = Join-Path $lane $planName

            @"
# Test plan

**Status**: ready
**Reviewed**: failed by opencode-go/hy3 - script missing

**PondLog**

```json
[]
```
"@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            $ctx = [PondContext]@{
                TaskRoot     = $taskRoot
                RepoDir      = $taskRoot
                CurrentGroup = [PondGroup]@{ StreamPath = $lane.FullName; Namespace = 'x'; RepoPath = $taskRoot }
                Success      = $false
            }

            $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Review' }
            $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

            Invoke-PondTaskTransition -Pond $pond -Task $task -Context $ctx

            $counter = Get-PondFeedbackFailureCounter -TaskRoot $taskRoot
            $counter.count | Should -Be 1
            $counter.investigatorPending | Should -BeFalse
            (Join-Path $taskRoot 'Investigate' '2026.08.28-sr-investigate-recurring-feedback.md') | Should -Not -Exist
        }

        It 'spawns a single Investigator plan when the counter reaches an even number' {
            $taskRoot = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'investigate-spawn-root') -Force).FullName
            Set-PondFeedbackFailureCounter -Counter @{ count = 0; investigatorPending = $false; lastFailureAt = $null; lastInvestigatorAt = $null } -TaskRoot $taskRoot

            # Seed one prior failure so the next feedback bumps the counter to 2 (even).
            Set-PondFeedbackFailureCounter -Counter @{ count = 1; investigatorPending = $false; lastFailureAt = (Get-Date -Format 'o'); lastInvestigatorAt = $null } -TaskRoot $taskRoot

            $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-qa-x-1') -Force
            $codeDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'QA') -Force
            $planName = '2026.08.28-qa-fail.md'
            $plan = Join-Path $lane $planName

            # Create a fake feedback plan in Code so the investigator plan has something to summarize.
            $feedbackName = '2026.08.28-qa-fail-feedback1.md'
            $feedback = @"
# Feedback plan: 2026.08.28-qa-fail

**Status**: ready
**PlanType**: feedback
**ParentPlan**: 2026.08.28-qa-fail.md
**FailedStage**: QA
**QA**: failed by qa - mutation score too low

## Feedback for Coder

**Source**: QA
**Verdict**: failed
**FailedChecks**: mutation score too low
**FixActions**: raise mutation score
"@
            $feedback | Set-Content -LiteralPath (Join-Path $codeDir $feedbackName) -Encoding utf8 -NoNewline

            @"
# Test plan

**Status**: ready
**QA**: failed by qa - mutation score too low

**PondLog**

```json
[]
```
"@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            $ctx = [PondContext]@{
                TaskRoot     = $taskRoot
                RepoDir      = $taskRoot
                CurrentGroup = [PondGroup]@{ StreamPath = $lane.FullName; Namespace = 'x'; RepoPath = $taskRoot }
                Success      = $false
            }

            $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'QA' }
            $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

            Invoke-PondTaskTransition -Pond $pond -Task $task -Context $ctx

            $counter = Get-PondFeedbackFailureCounter -TaskRoot $taskRoot
            $counter.count | Should -Be 2
            $counter.investigatorPending | Should -BeTrue

            $investigateDir = Join-Path $taskRoot 'Investigate'
            $investigateDir | Should -Exist
            $investigatorPlan = Get-ChildItem -LiteralPath $investigateDir -File -Filter '*.md' | Select-Object -First 1
            $investigatorPlan | Should -Not -BeNullOrEmpty

            $investigatorContent = Get-Content -LiteralPath $investigatorPlan.FullName -Raw
            $investigatorContent | Should -Match '\*\*PlanType\*\*:\s*investigation'
            $investigatorContent | Should -Match '\*\*Status\*\*:\s*ready'
            $investigatorContent | Should -Match 'mutation score too low'
        }

        It 'does not spawn a second Investigator while one is already pending' {
            $taskRoot = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'investigate-idempotent-root') -Force).FullName
            Set-PondFeedbackFailureCounter -Counter @{ count = 0; investigatorPending = $false; lastFailureAt = $null; lastInvestigatorAt = $null } -TaskRoot $taskRoot

            # Simulate counter at 2 with a pending investigator.
            Set-PondFeedbackFailureCounter -Counter @{ count = 2; investigatorPending = $true; lastFailureAt = (Get-Date -Format 'o'); lastInvestigatorAt = (Get-Date -Format 'o') } -TaskRoot $taskRoot

            # Also place a pending investigator plan on disk.
            $investigateDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Investigate') -Force
            'pending.md' | Set-Content -LiteralPath (Join-Path $investigateDir '2026.08.28-sr-investigate-recurring-feedback.md') -Encoding utf8 -NoNewline

            $ctx = [PondContext]@{
                TaskRoot = $taskRoot
                RepoDir  = $taskRoot
                Success  = $false
            }

            $result = Invoke-PondInvestigatorSpawn -Context $ctx
            $result | Should -BeNullOrEmpty
        }

        It 'clears the pending flag when an Investigator plan transitions' {
            $taskRoot = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'investigate-clear-root') -Force).FullName
            Set-PondFeedbackFailureCounter -Counter @{ count = 4; investigatorPending = $true; lastFailureAt = (Get-Date -Format 'o'); lastInvestigatorAt = (Get-Date -Format 'o') } -TaskRoot $taskRoot

            $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-investigator-sr-1') -Force
            $planName = '2026.08.28-sr-investigate-recurring-feedback.md'
            $plan = Join-Path $lane $planName

            @"
# Test plan

**Status**: ready
**InvestigatorDecision**: pass
**Investigated**: passed by opencode-go/hy3 - improved Code prompt

**PondLog**

```json
[]
```
"@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            $ctx = [PondContext]@{
                TaskRoot     = $taskRoot
                RepoDir      = $taskRoot
                CurrentGroup = [PondGroup]@{ StreamPath = $lane.FullName; Namespace = 'sr'; RepoPath = $taskRoot }
                Success      = $true
            }

            $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Investigate' }
            $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

            Invoke-PondTaskTransition -Pond $pond -Task $task -Context $ctx

            $counter = Get-PondFeedbackFailureCounter -TaskRoot $taskRoot
            $counter.investigatorPending | Should -BeFalse
        }
    }
}
