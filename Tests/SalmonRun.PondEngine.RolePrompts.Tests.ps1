#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

Describe 'Provider role prompts enforce the Salmon Run evidence contract' -Tag 'Contract', 'PondEngine', 'Regression' {
    BeforeAll {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $executorsDir = Join-Path $repoRoot 'Modules' 'SalmonRun.PondEngine' 'Executors'

        $script:RolePromptsFile = Join-Path $executorsDir 'RolePrompts.ps1'
        if (-not (Test-Path -LiteralPath $script:RolePromptsFile)) {
            throw "RolePrompts helper not found at $($script:RolePromptsFile)"
        }

        # Dot-source the shared helper directly; no provider-specific setup needed.
        . $script:RolePromptsFile

        # Map each role to the legacy evidence header the agent must emit.
        $script:ExpectedHeaders = @{
            'reviewer'         = 'Reviewed'
            'auditor'          = 'Audit'
            'qa'               = 'QA'
            'project-reviewer' = 'ProjectReview'
            'investigator'     = 'Investigated'
            'coder'            = 'Implementation'
        }

        $script:ExpectedDecisions = @{
            'reviewer'         = 'ReviewDecision'
            'auditor'          = 'AuditDecision'
            'qa'               = 'QADecision'
            'project-reviewer' = 'ProjectReviewDecision'
            'investigator'     = 'InvestigatorDecision'
        }
    }

    It 'produces a prompt containing the legacy evidence header for each evidence role' {
        foreach ($role in $ExpectedHeaders.Keys) {
            $prompt = Get-RolePrompt -Role $role -RepoDir 'C:\test' -Provider 'devin' -Model 'swe-1-7'
            $expected = $ExpectedHeaders[$role]
            $prompt | Should -Match "\*\*$expected\*\*: (passed|completed) by"
            $prompt | Should -Match '\*\*PondLog\*\*'
        }
    }

    It 'produces a prompt containing the decision header for roles that use decisions' {
        foreach ($role in $ExpectedDecisions.Keys) {
            $prompt = Get-RolePrompt -Role $role -RepoDir 'C:\test' -Provider 'devin' -Model 'swe-1-7'
            $expected = $ExpectedDecisions[$role]
            $prompt | Should -Match "\*\*$expected\*\*:\s*pass"
        }
    }

    It 'produces a prompt containing failure evidence instructions and feedback section' {
        foreach ($role in @('reviewer','auditor','qa')) {
            $prompt = Get-RolePrompt -Role $role -RepoDir 'C:\test' -Provider 'opencode-go' -Model 'opencode-go/hy3'
            $prompt | Should -Match 'Feedback for Coder'
            $prompt | Should -Match '## Feedback for Coder'
        }
    }

    It 'produces a prompt that names the agent using the provider/model tag' {
        $prompt = Get-RolePrompt -Role 'auditor' -RepoDir 'C:\test' -Provider 'devin' -Model 'swe-1-7'
        $prompt | Should -Match 'devin/swe-1-7'
    }

    It 'produces a prompt with the explicit target repository' {
        $prompt = Get-RolePrompt -Role 'qa' -RepoDir 'C:\test' -Provider 'codex' -Model 'gpt-5.6-luna'
        $prompt | Should -Match 'C:\\test'
    }

    Context 'Every external executor exposes a role prompt that includes the contract' {
        BeforeAll {
            $dummyLane = Join-Path $TestDrive 'lane'
            $dummyRepo = Join-Path $TestDrive 'repo'
            $dummyPlan = Join-Path $TestDrive 'plan.md'
            $null = New-Item -ItemType Directory -Path $dummyLane -Force
            $null = New-Item -ItemType Directory -Path $dummyRepo -Force
            '# Test plan' | Set-Content -LiteralPath $dummyPlan -Encoding utf8 -NoNewline

            # Prevent Write-PlanLog from trying to load PlanLog.ps1 during dot-source.
            if (-not (Get-Command Add-PlanPondLog -ErrorAction SilentlyContinue)) {
                function Add-PlanPondLog { param($PlanPath, $Entry) }
            }

            foreach ($name in 'Opencode','Devin','Dsh','Codex') {
                $path = Join-Path $executorsDir "$name.ps1"
                . $path -Role coder -LanePath $dummyLane -RepoDir $dummyRepo -PlanFiles $dummyPlan
            }
        }

        It 'Opencode returns a prompt with an implementation header for coder' {
            $p = Get-OpencodeRolePrompt -Role 'coder' -RepoDir $dummyRepo
            $p | Should -Match '\*\*Implementation\*\*: completed by'
        }

        It 'Devin returns a prompt with a QA header for qa' {
            $p = Get-DevinRolePrompt -Role 'qa'
            $p | Should -Match '\*\*QA\*\*: passed by'
        }

        It 'Dsh returns a prompt with an audit header for auditor' {
            $p = Get-DshRolePrompt -Role 'auditor'
            $p | Should -Match '\*\*Audit\*\*: passed by'
        }

        It 'Codex returns a prompt with a review header for reviewer' {
            $p = Get-CodexRolePrompt -Role 'reviewer'
            $p | Should -Match '\*\*Reviewed\*\*: passed by'
        }
    }
}
