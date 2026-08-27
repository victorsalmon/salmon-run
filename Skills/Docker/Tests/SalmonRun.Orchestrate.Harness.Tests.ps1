BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $moduleRoot = Join-Path $repoRoot 'Orchestrator\Modules\SalmonRun.Orchestrate'
    # Ensure SalmonRun.Paths is on the module path for Get-SkillsRoot
    $dockerModules = Join-Path $repoRoot 'Skills\Docker\Modules'
    if ($env:PSModulePath -notlike "*$dockerModules*") {
        $env:PSModulePath = "$dockerModules;${env:PSModulePath}"
    }
    Import-Module (Join-Path $dockerModules 'SalmonRun.Paths\SalmonRun.Paths.psd1') -Force -DisableNameChecking
    . (Join-Path $moduleRoot 'Private\HarnessConfig.ps1')
    . (Join-Path $moduleRoot 'Executors\Devin.ps1')
}

Describe 'Harness configuration resolution' -Tag 'Config', 'Orchestration' {
    It 'Defaults opencode harness to opencode-go provider and configured model' {
        $cfg = Resolve-HarnessConfig -Harness 'opencode'
        $cfg.Harness | Should -Be 'opencode'
        $cfg.Provider | Should -Be 'opencode-go'
        $cfg.Model | Should -Be 'opencode-go/ox-alpha-free'
        $cfg.Effort | Should -Be 'max'
        $cfg.ExecutorFile | Should -Be 'Opencode'
    }

    It 'Resolves devin harness to swe-1-7 with medium effort' {
        $cfg = Resolve-HarnessConfig -Harness 'devin'
        $cfg.Harness | Should -Be 'devin'
        $cfg.Provider | Should -Be 'devin'
        $cfg.Model | Should -Be 'swe-1-7'
        $cfg.Effort | Should -Be 'medium'
        $cfg.ExecutorFile | Should -Be 'Devin'
    }

    It 'Defaults deepseek harness to the DSH provider' {
        $cfg = Resolve-HarnessConfig -Harness 'deepseek'
        $cfg.Harness | Should -Be 'deepseek'
        $cfg.Provider | Should -Be 'dsh'
        $cfg.Model | Should -Be 'deepseek-v4-flash'
        $cfg.Effort | Should -Be 'max'
        $cfg.ExecutorFile | Should -Be 'Dsh'
    }

    It 'Defaults codex harness to DeepInfra V4 Flash 0731' {
        $cfg = Resolve-HarnessConfig -Harness 'codex'
        $cfg.Harness | Should -Be 'codex'
        $cfg.Provider | Should -Be 'deepinfra'
        $cfg.Model | Should -Be 'deepseek-ai/DeepSeek-V4-Flash-0731'
        $cfg.Effort | Should -Be 'medium'
        $cfg.ExecutorFile | Should -Be 'DeepInfra'
    }

    It 'Uses provided provider/model/effort overrides' {
        $cfg = Resolve-HarnessConfig -Harness 'opencode' -Provider 'opencode-go' -Model 'opencode-go/deepseek-v4-pro' -Effort 'default'
        $cfg.Model | Should -Be 'opencode-go/deepseek-v4-pro'
        $cfg.Effort | Should -Be 'default'
    }

    It 'Maps legacy -Executor values to harness/provider' {
        $cfg = Resolve-HarnessConfig -LegacyExecutor 'local'
        $cfg.Harness | Should -Be 'opencode'
        $cfg.Provider | Should -Be 'opencode-go'

        $cfg = Resolve-HarnessConfig -LegacyExecutor 'devin'
        $cfg.Harness | Should -Be 'devin'
        $cfg.Provider | Should -Be 'devin'

        $cfg = Resolve-HarnessConfig -LegacyExecutor 'dsh'
        $cfg.Harness | Should -Be 'deepseek'
        $cfg.Provider | Should -Be 'dsh'
    }

    It 'Falls back to accepted effort when an unknown effort is supplied' {
        $cfg = Resolve-HarnessConfig -Harness 'devin' -Effort 'high'
        $cfg.Effort | Should -Be 'medium'  # high is not accepted by devin provider
    }
}

Describe 'Plan execution-profile resolution' -Tag 'Config', 'Orchestration', 'Regression' {
    BeforeEach {
        $script:PlanProfileTemp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $script:PlanProfileTemp -Force
        $script:DefaultProfile = Resolve-HarnessConfig -Harness 'opencode'
    }

    AfterEach {
        Remove-Item -LiteralPath $script:PlanProfileTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'inherits the run default when every plan profile field is default' {
        $plan = Join-Path $script:PlanProfileTemp 'default.md'
        @"
**Overrides**: default
**Overrides confirmation**: not required
"@ | Set-Content -LiteralPath $plan -Encoding utf8
        $result = Get-PlanExecutionProfile -PlanPath $plan -DefaultConfig $script:DefaultProfile
        $result.HasOverride | Should -BeFalse
        $result.Config.Model | Should -Be $script:DefaultProfile.Model
    }

    It 'requires user confirmation for an explicit model profile' {
        $plan = Join-Path $script:PlanProfileTemp 'unconfirmed.md'
        '**Overrides**: Model=opencode-go/deepseek-v4-pro' | Set-Content -LiteralPath $plan -Encoding utf8
        { Get-PlanExecutionProfile -PlanPath $plan -DefaultConfig $script:DefaultProfile } | Should -Throw '*lacks*confirmation*'
    }

    It 'resolves a confirmed profile over the run default' {
        $plan = Join-Path $script:PlanProfileTemp 'confirmed.md'
        @"
**Overrides**: Harness=devin, Provider=devin, Model=swe-1-7, Effort=max
**Overrides confirmation**: confirmed by user
"@ | Set-Content -LiteralPath $plan -Encoding utf8
        $result = Get-PlanExecutionProfile -PlanPath $plan -DefaultConfig $script:DefaultProfile
        $result.HasOverride | Should -BeTrue
        $result.Config.Harness | Should -Be 'devin'
        $result.Config.Effort | Should -Be 'max'
    }

    It 'rejects incompatible profiles grouped into one stream' {
        $a = Join-Path $script:PlanProfileTemp 'a.md'
        $b = Join-Path $script:PlanProfileTemp 'b.md'
        @"
**Overrides**: Model=opencode-go/deepseek-v4-pro
**Overrides confirmation**: confirmed by user
"@ | Set-Content -LiteralPath $a -Encoding utf8
        @"
**Overrides**: Harness=devin, Provider=devin, Model=swe-1-7, Effort=medium
**Overrides confirmation**: confirmed by user
"@ | Set-Content -LiteralPath $b -Encoding utf8
        { Get-PlanExecutionProfile -PlanPath @($a, $b) -DefaultConfig $script:DefaultProfile } | Should -Throw '*incompatible Overrides*'
    }
}

Describe 'Skill path fallback' -Tag 'Config', 'Paths' {
    It 'Returns repo Skills root when it exists' {
        $root = Get-SkillsRoot -RepoRoot $repoRoot
        $root | Should -Be (Join-Path $repoRoot 'Skills')
    }

    It 'Falls back to parent Skills root when repo Skills is missing' {
        $fakeRepo = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $parentSkills = Join-Path ([System.IO.Path]::GetDirectoryName($fakeRepo)) 'Skills'
        $null = New-Item -ItemType Directory -Path (Join-Path $fakeRepo 'Other') -Force
        $null = New-Item -ItemType Directory -Path $parentSkills -Force
        try {
            $root = Get-SkillsRoot -RepoRoot $fakeRepo
            $root | Should -Be $parentSkills
        } finally {
            Remove-Item $fakeRepo -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $parentSkills -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Harness executor loader' -Tag 'Harness', 'Config', 'Regression' {
    It 'Resolves executor files for every declared harness' {
        $configs = @(
            (Resolve-HarnessConfig -Harness 'opencode'),
            (Resolve-HarnessConfig -Harness 'devin'),
            (Resolve-HarnessConfig -Harness 'deepseek'),
            (Resolve-HarnessConfig -Harness 'codex')
        )
        $configs.Count | Should -Be 4
        foreach ($cfg in $configs) {
            $executorFile = Join-Path $moduleRoot "Executors\$($cfg.ExecutorFile).ps1"
            Test-Path $executorFile | Should -Be $true -Because "executor $($cfg.ExecutorFile) for harness $($cfg.Harness) must exist"
        }
    }

    It 'Loads Executors\Devin.ps1 for the devin harness contract' {
        $functions = @('Initialize-Executor', 'Test-ExecutorPreflight', 'Start-StreamCoder', 'New-ExecutorTask', 'Stop-ExecutorTask', 'Get-ExecutorTaskStatus', 'Clear-AgentArtifacts', 'Invoke-ExecutorMerge', 'Get-DevinPrompt', 'Build-DevinPrompt')
        foreach ($fn in $functions) {
            (Get-Command $fn -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty -Because "$fn must exist in Devin.ps1"
        }
    }

    It 'Declares the DeepInfra executor contract' {
        $executorFile = Join-Path $moduleRoot 'Executors\DeepInfra.ps1'
        $source = Get-Content -LiteralPath $executorFile -Raw
        foreach ($fn in @('Initialize-Executor', 'Test-ExecutorPreflight', 'Start-StreamCoder', 'New-ExecutorTask', 'Stop-ExecutorTask', 'Get-ExecutorTaskStatus', 'Clear-AgentArtifacts', 'Invoke-ExecutorMerge')) {
            $source | Should -Match "function\s+$fn\b" -Because "$fn must exist in DeepInfra.ps1"
        }
        $source | Should -Match 'model_provider = "deepinfra-relay"'
        $source | Should -Match 'wire_api = "responses"'
        $source | Should -Match 'requires_openai_auth = false'
    }
}

Describe 'Devin prompt templates' -Tag 'Devin', 'Harness', 'Regression' {
    It 'Renders the coder template with placeholders substituted' {
        $prompt = Get-DevinPrompt -Role 'coder' -Namespace 'test-ns' -ProjectRoot 'C:/repo'
        $prompt | Should -Match 'Role: coder'
        $prompt | Should -Match 'Namespace: test-ns'
        $prompt | Should -Match 'Project root: C:/repo'
        $prompt | Should -Not -Match '\{\{'
    }

    It 'Renders the reviewer template with placeholders substituted' {
        $prompt = Get-DevinPrompt -Role 'reviewer' -Namespace 'test-ns' -ProjectRoot 'C:/repo'
        $prompt | Should -Match 'Role: reviewer'
        $prompt | Should -Not -Match '\{\{'
    }

    It 'Includes branch and worktree when provided' {
        $prompt = Get-DevinPrompt -Role 'coder' -Namespace 'test-ns' -ProjectRoot 'C:/repo' -BranchName 'wt/lane-1' -WorktreePath 'C:/repo/Tasks/worktrees/lane-1'
        $prompt | Should -Match 'Branch: wt/lane-1'
        $prompt | Should -Match 'Worktree: C:/repo/Tasks/worktrees/lane-1'
        $prompt | Should -Not -Match '\{\{'
    }

    It 'Builds a coder prompt that embeds the plan body and role' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tmp -Force
        try {
            $plan = Join-Path $tmp 'plan.md'
            '## Tasks' | Out-File -FilePath $plan -Encoding utf8
            $prompt = Build-DevinPrompt -Role 'coder' -StreamDir $tmp -Namespace 'test-ns' -InterclawDir 'C:/repo'
            $prompt | Should -Match 'Role: coder'
            $prompt | Should -Match '## Plan: plan.md'
            $prompt | Should -Match '## Tasks'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Devin ACP merge helpers' -Tag 'Config', 'Merge', 'Regression' {
    It 'Builds a merge prompt from a merge feedback file' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tmp -Force
        try {
            $plan = Join-Path $tmp 'merge-feedback.md'
            'Resolve conflict in file A and B' | Out-File -FilePath $plan -Encoding utf8
            $prompt = Build-DevinMergePrompt -MergePlan $plan -BranchName 'wt/module-1' -WorktreePath (Join-Path $tmp 'wt') -InterclawDir $tmp
            $prompt | Should -Match 'Role: merge'
            $prompt | Should -Match 'wt/module-1'
            $prompt | Should -Match 'Resolve conflict in file A and B'
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns 1 when ACP output contains an error record' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tmp -Force
        try {
            $out = Join-Path $tmp 'stdout'
            '{"type":"error","message":"auth failed"}' | Out-File -FilePath $out -Encoding utf8
            Get-DevinAcpExitCode -OutFile $out | Should -Be 1
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns 1 when ACP stopReason is not success/end_turn' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tmp -Force
        try {
            $out = Join-Path $tmp 'stdout'
            '{"type":"result","stopReason":"timeout"}' | Out-File -FilePath $out -Encoding utf8
            Get-DevinAcpExitCode -OutFile $out | Should -Be 1
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Returns 0 when ACP result is end_turn' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $tmp -Force
        try {
            $out = Join-Path $tmp 'stdout'
            '{"type":"result","stopReason":"end_turn"}' | Out-File -FilePath $out -Encoding utf8
            Get-DevinAcpExitCode -OutFile $out | Should -Be 0
        } finally {
            Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
