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
        'completed operational log' | Set-Content -LiteralPath (Join-Path $lane 'executor.log') -NoNewline
        $ctx = [PondContext]@{ TaskRoot=$taskRoot; RepoDir=$taskRoot; CurrentGroup=[PondGroup]@{ StreamPath=$lane; Namespace='time'; RepoPath=$taskRoot }; Success=$false; Config=[pscustomobject]@{ TimeoutMinutes=30 } }
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Review
        $task = $pond.Tasks | Where-Object Name -eq Transition | Select-Object -First 1
        $script:lanePresentAtCheckpoint = $null
        Mock Push-PondRepos { $script:lanePresentAtCheckpoint = Test-Path -LiteralPath $Context.CurrentGroup.StreamPath } -ModuleName SalmonRun.PondEngine
        { & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx } | Should -Not -Throw
        Join-Path $taskRoot "Code/$planName" | Should -Exist
        Join-Path $taskRoot "Review/$planName" | Should -Not -Exist
        $lane.FullName | Should -Not -Exist
        $script:lanePresentAtCheckpoint | Should -BeFalse
    }

    It 'links Review feedback to the canonical plan returned to Code' {
        $taskRoot=New-Item -ItemType Directory -Path (Join-Path $TestDrive 'feedback-transition-root') -Force; $lane=New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working/lane-reviewer-x-1') -Force; $null=New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $planName='2026.08.28-review-fail.md';$plan=Join-Path $lane $planName;"# Test`n**Status**: ready`n**Reviewed**: failed by test - script missing"|Set-Content $plan -NoNewline
        $ctx=[PondContext]@{TaskRoot=$taskRoot;RepoDir=$taskRoot;CurrentGroup=[PondGroup]@{StreamPath=$lane;Namespace='x';RepoPath=$taskRoot};Success=$false};$pond=Get-SalmonRunPonds|Where-Object Name -eq Review;$task=$pond.Tasks|Where-Object Name -eq Transition|Select-Object -First 1
        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx
        $moved=Join-Path $taskRoot "Code/$planName";$moved|Should -Exist;@(Get-ChildItem (Join-Path $taskRoot 'Code') -Filter '*feedback*.md').Count|Should -Be 0
        $body=Get-Content $moved -Raw;$body|Should -Match '\*\*Feedback\*\*:\s*Results/';$body|Should -Match '\*\*Status\*\*:\s*ready'
        (Get-PlanPondLog $moved|Where-Object action -eq feedback)|Should -Not -BeNullOrEmpty
    }
    It 'links QA feedback without cloning the plan family' {
        $taskRoot=New-Item -ItemType Directory -Path (Join-Path $TestDrive 'feedback-qa-root') -Force;$lane=New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Working/lane-qa-x-1') -Force;$null=New-Item -ItemType Directory -Path (Join-Path $taskRoot 'Code') -Force
        $planName='2026.08.28-qa-fail.md';$plan=Join-Path $lane $planName;"# Test`n**Status**: ready`n**QA**: failed by test - mutation score too low"|Set-Content $plan -NoNewline
        $ctx=[PondContext]@{TaskRoot=$taskRoot;RepoDir=$taskRoot;CurrentGroup=[PondGroup]@{StreamPath=$lane;Namespace='x';RepoPath=$taskRoot};Success=$false};$pond=Get-SalmonRunPonds|Where-Object Name -eq QA;$task=$pond.Tasks|Where-Object Name -eq Transition|Select-Object -First 1
        & (Get-Module SalmonRun.PondEngine) { param($p,$t,$c) Invoke-PondTaskTransition -Pond $p -Task $t -Context $c } $pond $task $ctx
        $moved=Join-Path $taskRoot "Code/$planName";$moved|Should -Exist;@(Get-ChildItem (Join-Path $taskRoot 'Code') -Filter '*feedback*.md').Count|Should -Be 0
        $body=Get-Content $moved -Raw;$relative=([regex]::Match($body,'(?im)^\*\*Feedback\*\*:\s*(?<v>[^\r\n]+)')).Groups['v'].Value.Trim();$sidecar=Join-Path (Split-Path $taskRoot -Parent) $relative
        $feedback=Get-Content $sidecar -Raw|ConvertFrom-Json;$feedback.gate|Should -Be QA;$feedback.reason|Should -Be 'mutation score too low'
    }
}
