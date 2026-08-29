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

Describe 'Failing transitions append structured feedback for the Coder' -Tag 'PondEngine','Feedback','Regression' {
    It 'moves a failed Review plan back to Code with a Feedback for Coder section' {
        $taskRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'feedback-transition-root') -Force
        $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-reviewer-x-1') -Force
        $codeDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $plan = Join-Path $lane 'plan.md'

        @'
# Test plan

**Status**: ready
**Reviewed**: failed by opencode-go/hy3 - script missing; test failing; docs incomplete

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $ctx = [PondContext]@{
            TaskRoot     = $taskRoot
            RepoDir      = $taskRoot
            CurrentGroup = [PondGroup]@{ StreamPath = $lane; Namespace = 'x'; RepoPath = $taskRoot }
            Success      = $false
        }

        $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Review' }
        $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx

        $movedPlan = Join-Path $codeDir 'plan.md'
        $movedPlan | Should -Exist

        $content = Get-Content -LiteralPath $movedPlan -Raw
        $content | Should -Match '## Feedback for Coder'
        $content | Should -Match '\*\*Source\*\*:\s*Review'
        $content | Should -Match '\*\*Verdict\*\*:\s*failed'
        $content | Should -Match '\*\*FailedChecks\*\*:'
        $content | Should -Match '1\. script missing'
        $content | Should -Match '2\. test failing'
        $content | Should -Match '3\. docs incomplete'
        $content | Should -Match '\*\*FixActions\*\*:'
        $content | Should -Match '\*\*Status\*\*:\s*ready'

        $log = Get-PlanPondLog -PlanPath $movedPlan
        $log | Where-Object { $_.action -eq 'retry' } | Should -Not -BeNullOrEmpty
    }

    It 'does not overwrite an existing Feedback for Coder section' {
        $taskRoot = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'feedback-preserve-root') -Force
        $lane = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working' 'lane-qa-x-1') -Force
        $codeDir = New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $plan = Join-Path $lane 'plan.md'

        @'
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
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $ctx = [PondContext]@{
            TaskRoot     = $taskRoot
            RepoDir      = $taskRoot
            CurrentGroup = [PondGroup]@{ StreamPath = $lane; Namespace = 'x'; RepoPath = $taskRoot }
            Success      = $false
        }

        $pond = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'QA' }
        $task = $pond.Tasks | Where-Object { $_.Name -eq 'Transition' } | Select-Object -First 1

        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx

        $movedPlan = Join-Path $codeDir 'plan.md'
        $movedPlan | Should -Exist

        $content = Get-Content -LiteralPath $movedPlan -Raw
        $content | Should -Match '1\. Add property tests for edge cases'
        ($content | Select-String -Pattern '## Feedback for Coder').Count | Should -Be 1
    }
}
