#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $script:OpencodeScript = Join-Path $__RepoRoot 'Modules/SalmonRun.PondEngine/Executors/Opencode.ps1'

    $env:PSModulePath = "$__RepoRoot\Modules$([System.IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module 'SalmonRun.PondEngine' -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $__RepoRoot 'Modules/SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force -ErrorAction Stop
}

$feedbackPromptCases = @(
    @{ Role = 'coder'; Patterns = @('Feedback for Coder','FixActions','FailedChecks','Reviewed.*failed','QA.*failed','Audit.*failed') }
    @{ Role = 'reviewer'; Patterns = @('Feedback for Coder','FixActions','FailedChecks','Source.*Review') }
    @{ Role = 'auditor'; Patterns = @('Feedback for Coder','FixActions') }
    @{ Role = 'qa'; Patterns = @('Feedback for Coder','FixActions') }
)

Describe 'OpenCode role prompts surface semantic feedback to coders' -Tag 'PondEngine','Feedback','Regression' {
    It 'role <Role> prompt includes feedback instructions' -TestCases $feedbackPromptCases {
        param([string]$Role, [string[]]$Patterns)

        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "feedback-$Role-$(Get-Random)") -Force
        $plan = Join-Path $td 'plan.md'
        @'
# Test plan

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        . $script:OpencodeScript -Role $Role -LanePath $td -RepoDir $td -PlanFiles @($plan)
        $prompt = Get-OpencodeRolePrompt -Role $Role -RepoDir $td

        foreach ($pattern in $Patterns) {
            $prompt | Should -Match $pattern
        }
    }
}

Describe 'Failing transitions create feedback plans in Code and block originals' -Tag 'PondEngine','Feedback','Regression' {
    It 'classifies timestamped external failures without throwing and preserves the failing pond' {
        $taskRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'timestamp-transition-root') -Force
        $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-reviewer-time-1') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Review') -Force
        $planName = '2026.08.29-review-time.md'
        $plan = Join-Path $lane $planName
        $planContent = "# Test plan`n**Status**: ready`n**Reviewed**: failed by opencode-go/hy3 - current verification failed`n`n**PondLog**`n``````json`n[{`"ts`":`"2026-08-29T16:00:00Z`",`"pond`":`"Review`",`"role`":`"reviewer`",`"action`":`"spawn`",`"detail`":`"started`",`"agent`":`"test`"},{`"ts`":`"2026-08-29T16:01:00Z`",`"pond`":`"Review`",`"role`":`"reviewer`",`"action`":`"external-fail`",`"detail`":`"exit=2`",`"agent`":`"test`"}]`n``````"
        $planContent | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline
        $ctx = [PondContext]@{ TaskRoot=$taskRoot; RepoDir=$taskRoot; CurrentGroup=[PondGroup]@{ StreamPath=$lane; Namespace='time'; RepoPath=$taskRoot }; Success=$false; Config=[pscustomobject]@{ TimeoutMinutes=30 } }
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Review
        $task = $pond.Tasks | Where-Object Name -eq Transition | Select-Object -First 1
        { & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx } | Should -Not -Throw
        Join-Path $taskRoot "Review/$planName" | Should -Exist
        Join-Path $taskRoot "Code/$planName" | Should -Not -Exist
    }

    It 'blocks a failed Review plan in Review and creates a Code feedback plan' {
        $taskRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'feedback-transition-root') -Force
        $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-reviewer-x-1') -Force
        $codeDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $reviewDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Review') -Force
        $planName = '2026.08.28-review-fail.md'
        $plan = Join-Path $lane $planName

        @"
# Test plan

**Status**: ready
**Reviewed**: failed by opencode-go/hy3 - script missing; test failing; docs incomplete

**PondLog**

```json
[]
```
"@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $ctx = [PondContext]@{
            TaskRoot     = $taskRoot
            RepoDir      = $taskRoot
            CurrentGroup = [PondGroup]@{ StreamPath = $lane; Namespace = 'x'; RepoPath = $taskRoot }
            Success      = $false
        }

        $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Review' }
        $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx

        $movedPlan = Join-Path $reviewDir $planName
        $feedbackName = '2026.08.28-review-fail-feedback1.md'
        $feedbackPlan = Join-Path $codeDir $feedbackName

        $movedPlan | Should -Exist
        $feedbackPlan | Should -Exist
        Join-Path $codeDir $planName | Should -Not -Exist

        $reviewContent = Get-Content -LiteralPath $movedPlan -Raw
        $reviewContent | Should -Match '\*\*Blocked\*\*:\s*true'
        $reviewContent | Should -Match '\*\*BlockedBy\*\*:\s*Review'
        $reviewContent | Should -Match '\*\*BlockedReason\*\*:\s*script missing; test failing; docs incomplete'
        $reviewContent | Should -Match "\*\*WaitingFor\*\*:\s*$([regex]::Escape($feedbackName))"
        $reviewContent | Should -Match '\*\*Status\*\*:\s*blocked'

        $feedbackContent = Get-Content -LiteralPath $feedbackPlan -Raw
        $feedbackContent | Should -Match '# Feedback plan: 2026.08.28-review-fail'
        $feedbackContent | Should -Match '\*\*Status\*\*:\s*ready'
        $feedbackContent | Should -Match '\*\*Scope\*\*:\s*Feedback for 2026.08.28-review-fail'
        $feedbackContent | Should -Match '\*\*PlanType\*\*:\s*feedback'
        $feedbackContent | Should -Match "\*\*ParentPlan\*\*:\s*$([regex]::Escape($planName))"
        $feedbackContent | Should -Match '\*\*FailedStage\*\*:\s*Review'
        $feedbackContent | Should -Match '\*\*Reviewed\*\*:\s*failed by reviewer - script missing; test failing; docs incomplete'
        $feedbackContent | Should -Match '## Feedback for Coder'
        $feedbackContent | Should -Match '\*\*Source\*\*:\s*Review'
        $feedbackContent | Should -Match '\*\*Verdict\*\*:\s*failed'
        $feedbackContent | Should -Match '\*\*FailedChecks\*\*:'
        $feedbackContent | Should -Match '1\. script missing'
        $feedbackContent | Should -Match '2\. test failing'
        $feedbackContent | Should -Match '3\. docs incomplete'
        $feedbackContent | Should -Match '\*\*FixActions\*\*:'

        $feedbackLog = Get-PlanPondLog -PlanPath $feedbackPlan
        $feedbackLog | Where-Object { $_.action -eq 'created' } | Should -Not -BeNullOrEmpty

        $reviewLog = Get-PlanPondLog -PlanPath $movedPlan
        $reviewLog | Where-Object { $_.action -eq 'feedback' } | Should -Not -BeNullOrEmpty
    }

    It 'blocks a failed QA plan in QA and creates a fresh feedback plan in Code' {
        $taskRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'feedback-preserve-root') -Force
        $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-qa-x-1') -Force
        $codeDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $qaDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'QA') -Force
        $planName = '2026.08.28-qa-fail.md'
        $plan = Join-Path $lane $planName

        @"
# Test plan

**Status**: ready
**QA**: failed by opencode-go/hy3 - mutation score too low

## Feedback for Coder

**Source**: QA
**Verdict**: failed
**FailedChecks**:
1. mutation score too low
**FixActions**:
1. Add property tests for edge cases.

**PondLog**

```json
[]
```
"@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $ctx = [PondContext]@{
            TaskRoot     = $taskRoot
            RepoDir      = $taskRoot
            CurrentGroup = [PondGroup]@{ StreamPath = $lane; Namespace = 'x'; RepoPath = $taskRoot }
            Success      = $false
        }

        $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'QA' }
        $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx

        $movedPlan = Join-Path $qaDir $planName
        $feedbackName = '2026.08.28-qa-fail-feedback1.md'
        $feedbackPlan = Join-Path $codeDir $feedbackName

        $movedPlan | Should -Exist
        $feedbackPlan | Should -Exist
        Join-Path $codeDir $planName | Should -Not -Exist

        $qaContent = Get-Content -LiteralPath $movedPlan -Raw
        $qaContent | Should -Match '\*\*Blocked\*\*:\s*true'
        $qaContent | Should -Match '\*\*BlockedBy\*\*:\s*QA'
        $qaContent | Should -Match '\*\*BlockedReason\*\*:\s*mutation score too low'
        $qaContent | Should -Match "\*\*WaitingFor\*\*:\s*$([regex]::Escape($feedbackName))"
        $qaContent | Should -Match '\*\*Status\*\*:\s*blocked'
        ($qaContent | Select-String -Pattern '## Feedback for Coder').Count | Should -Be 1

        $feedbackContent = Get-Content -LiteralPath $feedbackPlan -Raw
        $feedbackContent | Should -Match '# Feedback plan: 2026.08.28-qa-fail'
        $feedbackContent | Should -Match '\*\*Status\*\*:\s*ready'
        $feedbackContent | Should -Match '\*\*PlanType\*\*:\s*feedback'
        $feedbackContent | Should -Match '\*\*FailedStage\*\*:\s*QA'
        $feedbackContent | Should -Match '\*\*QA\*\*:\s*failed by qa - mutation score too low'
        $feedbackContent | Should -Match '## Feedback for Coder'
        $feedbackContent | Should -Match '1\. mutation score too low'
        ($feedbackContent | Select-String -Pattern '## Feedback for Coder').Count | Should -Be 1

        $feedbackLog = Get-PlanPondLog -PlanPath $feedbackPlan
        $feedbackLog | Where-Object { $_.action -eq 'created' } | Should -Not -BeNullOrEmpty

        $qaLog = Get-PlanPondLog -PlanPath $movedPlan
        $qaLog | Where-Object { $_.action -eq 'feedback' } | Should -Not -BeNullOrEmpty
    }
}
