#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Modules'

    $env:PSModulePath = "$__ModulesDir$([System.IO.Path]::PathSeparator)$env:PSModulePath"

    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }

    # Ensure a clean module load in case other test files have left stale
    # orchestrator/pond state in the same session.
    Remove-Module 'SalmonRun.PondEngine', 'SalmonRun.Paths', 'SalmonRun.Constants', 'SalmonRun.Core', 'SalmonRun.AgentLifecycle' -Force -ErrorAction SilentlyContinue

    $script:PondEnginePsd1 = Join-Path $__ModulesDir 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psd1'
    Import-Module $script:PondEnginePsd1 -Force -ErrorAction Stop

    # Isolate the runtime home so provider overlays in the real ~/.salmon do not
    # leak into these tests. Tests that need a specific runtime layout override
    # this in their own It blocks.
    $script:SavedSalmonRunHome = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = Join-Path $TestDrive 'salmon-home'
    $null = New-Item -ItemType Directory -Path $env:SALMON_RUN_HOME -Force
}

AfterAll {
    $env:SALMON_RUN_HOME = $script:SavedSalmonRunHome
}

Describe 'SalmonRun.PondEngine Module Manifest' -Tag 'PondEngine', 'Regression-Only' {
    It 'psd1 exists' {
        Test-Path $script:PondEnginePsd1 | Should -Be $true
    }

    It 'exports the expected functions' {
        $manifest = Import-PowerShellDataFile -Path $script:PondEnginePsd1
        $manifest.FunctionsToExport | Should -Contain 'Get-SalmonRunPonds'
        $manifest.FunctionsToExport | Should -Contain 'Start-PondEngine'
    }
}

Describe 'Get-SalmonRunPonds' -Tag 'PondEngine', 'Regression-Only' {
    It 'returns a non-empty array of Ponds' {
        $ponds = Get-SalmonRunPonds
        $ponds | Should -Not -BeNullOrEmpty
        $ponds.Count | Should -BeGreaterThan 0
        $ponds[0] | Should -BeOfType [Pond]
    }

    It 'includes the expected pond names' {
        $ponds = Get-SalmonRunPonds
        $names = $ponds | ForEach-Object { $_.Name }
        $expected = @('Intake', 'Code', 'Review', 'Audit', 'QA', 'Project', 'ProjectReview', 'Complete')
        foreach ($name in $expected) {
            $names | Should -Contain $name
        }
    }

    It 'gives every pond a folder, role, and operators' {
        $ponds = Get-SalmonRunPonds
        foreach ($p in $ponds) {
            $p.Folder | Should -Not -BeNullOrEmpty -Because "pond '$($p.Name)' should have a folder"
            $p.Role | Should -Not -BeNullOrEmpty -Because "pond '$($p.Name)' should have a role"
            $p.Operators | Should -Not -BeNullOrEmpty -Because "pond '$($p.Name)' should have operators"
            $p.Operators.ParallelCount | Should -BeGreaterOrEqual 1
        }
    }

    It 'uses the default operator template' {
        $code = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Code' }
        $code.Operators.ParallelCount | Should -Be 3
        $review = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Review' }
        $review.Operators.ParallelCount | Should -Be 1
        $audit = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Audit' }
        $audit.Operators.ParallelCount | Should -Be 1
        $qa = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'QA' }
        $qa.Operators.ParallelCount | Should -Be 1
    }

    It 'has success transitions between expected ponds' {
        $ponds = Get-SalmonRunPonds | Where-Object { $_.Name -in @('Code', 'Review', 'Audit', 'QA', 'Project', 'ProjectReview') }
        $map = @{}
        foreach ($p in $ponds) { $map[$p.Name] = $p.OnSuccess.MoveTo }

        $map['Code'] | Should -Be 'Review'
        $map['Review'] | Should -Be 'Audit'
        $map['Audit'] | Should -Be 'QA'
        $map['QA'] | Should -Be 'Complete'
        $map['Project'] | Should -Be 'ProjectReview'
        $map['ProjectReview'] | Should -Be 'Complete'
    }

    It 'parks invalid plans instead of failing them by default' {
        $ponds = Get-SalmonRunPonds | Where-Object { $_.Name -in @('Code', 'Review') }
        foreach ($p in $ponds) {
            $p.Entry.OnInvalid | Should -Be 'Paused' -Because "pond '$($p.Name)' should park invalid plans"
        }
    }

    It 'routes Review failures back to Code so feedback can be written to Code' {
        $review = Get-SalmonRunPonds | Where-Object { $_.Name -eq 'Review' }
        $review.OnFailure.MoveTo | Should -Be 'Code'
    }
}

Describe 'Start-PondEngine dry run' -Tag 'PondEngine', 'Regression-Only' {
    It 'does not crash with a single ready Code plan' {
        $tempDir = Join-Path $TestDrive 'pondengine-dryrun'
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Failed" -Force
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Complete" -Force
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Paused" -Force
        "# Session Plan: test`n**Status**: ready`n**Scope**: something" | Set-Content "$tempDir/Tasks/Code/2026-08-25-ns-test-1-task.md" -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            { Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 0 } | Should -Not -Throw
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }

    It 'parks a Code plan missing required headers' {
        $tempDir = Join-Path $TestDrive 'pondengine-park'
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
        $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Paused" -Force
        "# Session Plan: test" | Set-Content "$tempDir/Tasks/Code/2026-08-25-ns-test-2-task.md" -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 0
            "$tempDir/Tasks/Paused/2026-08-25-ns-test-2-task.md" | Should -Exist
            "$tempDir/Tasks/Code/2026-08-25-ns-test-2-task.md" | Should -Not -Exist
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }
}

Describe 'Pond classes' -Tag 'PondEngine', 'Regression-Only' {
    It 'can construct a PondContext' {
        $c = [PondContext]::new()
        $c | Should -Not -BeNullOrEmpty
    }

    It 'can construct a PondGroup' {
        $g = [PondGroup]::new()
        $g | Should -Not -BeNullOrEmpty
    }

    It 'can construct a PondStream with default lanes' {
        $stream = New-PondStream -Id 'stream-1' -Branch 'main' -Path 'C:\temp\repo'
        $stream | Should -Not -BeNullOrEmpty
        $stream.Lanes.Count | Should -Be 10
    }

    It 'has the expected role lane counts' {
        $stream = New-PondStream -Id 'stream-1' -Branch 'main' -Path 'C:\temp\repo'
        $roles = $stream.Lanes.Values | Group-Object Role | ForEach-Object { @{ $_.Name = $_.Count } }
        $coder = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'coder' }).Count
        $reviewer = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'reviewer' }).Count
        $auditor = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'auditor' }).Count
        $qa = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'qa' }).Count
        $projectPlanner = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'project-planner' }).Count
        $projectReviewer = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'project-reviewer' }).Count
        $archiver = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'archiver' }).Count
        $coder | Should -Be 3
        $reviewer | Should -Be 1
        $auditor | Should -Be 1
        $qa | Should -Be 1
        $projectPlanner | Should -Be 2
        $projectReviewer | Should -Be 1
        $archiver | Should -Be 1
    }
}

Describe 'Pond executor registry' -Tag 'PondEngine', 'Regression-Only' {
    It 'resolves a Daily profile from the model-router catalog' {
        $srExecProfile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Daily' }
        $srExecProfile | Should -Not -BeNullOrEmpty
        $srExecProfile.Harness | Should -Not -BeNullOrEmpty
        $srExecProfile.Provider | Should -Not -BeNullOrEmpty
        $srExecProfile.Model | Should -Not -BeNullOrEmpty
        $srExecProfile.Effort | Should -Not -BeNullOrEmpty
        $srExecProfile.Cli | Should -Not -BeNullOrEmpty
        $srExecProfile.ExecutorFile | Should -Not -BeNullOrEmpty
    }

    It 'routes every tier to the configured opencode-go model' {
        $flash = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Flash' }
        $frontier = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }
        $flash.Provider | Should -Be 'opencode-go'
        $frontier.Provider | Should -Be 'opencode-go'
        $flash.Model | Should -Be 'opencode-go/hy3'
        $frontier.Model | Should -Be 'opencode-go/hy3'
    }

    It 'produces a runnable executor command from a profile' {
        $srExecProfile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Daily' }
        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'coder' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile
        $cmd.ExecutorPath | Should -Exist
        $cmd.Command | Should -Match $srExecProfile.Model

        if ($srExecProfile.Cli -eq 'opencode') {
            $cmd.Command | Should -Match 'opencode run'
            $cmd.Command | Should -Match '--variant'
            $cmd.Command | Should -Match '--auto'
        } elseif ($srExecProfile.Cli -eq 'codex') {
            $cmd.Command | Should -Match 'codex exec'
            $cmd.Command | Should -Match 'model_reasoning_effort'
            $cmd.Command | Should -Match '--output-last-message'
        }
    }

    It 'writes a .run sentinel when spawning an agent' {
        $td = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "pondengine-spawn-$([System.Guid]::NewGuid().ToString('n').Substring(0,8))") -Force
        try {
            $planPath = Join-Path $td 'plan.md'
            "# test" | Set-Content -LiteralPath $planPath -Encoding utf8 -NoNewline
            $command = [PSCustomObject]@{
                ExecutorPath = 'C:\temp\executor.ps1'
                Command = 'opencode run --command work-coder-once'
                Role = 'coder'
                RepoDir = $td
                PlanFiles = @($planPath)
            }
            & (Get-Module SalmonRun.PondEngine) { param($c, $l, $p) Start-PondExecutor -Command $c -LanePath $l -LogPath $p } $command $td (Join-Path $td 'log.log')
            Join-Path $td '.run' | Should -Exist
            Join-Path $td '.pid' | Should -Exist
        } finally {
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Start-PondEngine end-to-end with local executor' -Tag 'PondEngine', 'Regression-Only' {
    It 'moves a Code plan to Complete using the Local harness' {
        $tempDir = Join-Path $TestDrive 'pondengine-e2e'
        foreach ($sub in @('Tasks/Code','Tasks/Review','Tasks/Audit','Tasks/QA','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $planContent = @"
# E2E Plan
**Status**: ready
**Scope**: test
**Challenge**: Local
"@
        $planName = '2026-08-26-e2e-local-test.md'
        $planContent | Set-Content -LiteralPath (Join-Path $tempDir "Tasks/Code/$planName") -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Complete/$planName" | Should -Exist
            Join-Path $tempDir "Tasks/Code/$planName" | Should -Not -Exist
            Join-Path $tempDir "Tasks/Failed/$planName" | Should -Not -Exist
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }
}

Describe 'Pond dependency gating' -Tag 'PondEngine', 'Regression-Only' {
    It 'holds a Code plan until its DependsOn plan reaches Complete' {
        $tempDir = Join-Path $TestDrive 'pondengine-depends'
        foreach ($sub in @('Tasks/Code','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $parentContent = @"
# Parent Plan
**Status**: complete
"@
        $parentContent | Set-Content -LiteralPath (Join-Path $tempDir 'Tasks/Complete/2026-08-26-parent.md') -Encoding utf8 -NoNewline

        $childContent = @"
# Child Plan
**Status**: ready
**Scope**: test
**Challenge**: Local
**DependsOn**: 2026-08-26-parent
"@
        $childContent | Set-Content -LiteralPath (Join-Path $tempDir 'Tasks/Code/2026-08-26-child.md') -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Complete/2026-08-26-child.md" | Should -Exist
            Join-Path $tempDir "Tasks/Code/2026-08-26-child.md" | Should -Not -Exist
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }

    It 'keeps a Code plan in Code when its DependsOn plan is not yet Complete' {
        $tempDir = Join-Path $TestDrive 'pondengine-depends-blocked'
        foreach ($sub in @('Tasks/Code','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $childContent = @"
# Child Plan
**Status**: ready
**Scope**: test
**DependsOn**: 2026-08-26-missing-parent
"@
        $childContent | Set-Content -LiteralPath (Join-Path $tempDir 'Tasks/Code/2026-08-26-child.md') -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Code/2026-08-26-child.md" | Should -Exist
            Join-Path $tempDir "Tasks/Complete/2026-08-26-child.md" | Should -Not -Exist
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }

    It 'waits for all comma-separated DependsOn plans to reach Complete' {
        $tempDir = Join-Path $TestDrive 'pondengine-depends-multi'
        foreach ($sub in @('Tasks/Code','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $parentA = @"
# Parent A
**Status**: complete
"@
        $parentA | Set-Content -LiteralPath (Join-Path $tempDir 'Tasks/Complete/2026-08-26-parent-a.md') -Encoding utf8 -NoNewline

        $parentB = @"
# Parent B
**Status**: complete
"@
        $parentB | Set-Content -LiteralPath (Join-Path $tempDir 'Tasks/Complete/2026-08-26-parent-b.md') -Encoding utf8 -NoNewline

        $childContent = @"
# Child Plan
**Status**: ready
**Scope**: test
**Challenge**: Local
**DependsOn**: 2026-08-26-parent-a, 2026-08-26-parent-b
"@
        $childContent | Set-Content -LiteralPath (Join-Path $tempDir 'Tasks/Code/2026-08-26-child.md') -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Complete/2026-08-26-child.md" | Should -Exist
            Join-Path $tempDir "Tasks/Code/2026-08-26-child.md" | Should -Not -Exist
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }
}

Describe 'Project and ProjectReview pipeline' -Tag 'PondEngine', 'Regression-Only' {
    It 'moves a Project plan through ProjectReview to Complete with Local harness' {
        $tempDir = Join-Path $TestDrive 'pondengine-project'
        foreach ($sub in @('Tasks/Code','Tasks/Review','Tasks/Audit','Tasks/QA','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed','Tasks/Project','Tasks/ProjectReview')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $planName = '2026-08-26-e2e-project.md'
        $planContent = @"
# E2E Project Plan
**Status**: ready
**Scope**: test
**Challenge**: Local
**Children**: child-a
"@
        $planContent | Set-Content -LiteralPath (Join-Path $tempDir "Tasks/Project/$planName") -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 8 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Complete/$planName" | Should -Exist
            Join-Path $tempDir "Tasks/Project/$planName" | Should -Not -Exist
            Join-Path $tempDir "Tasks/Failed/$planName" | Should -Not -Exist
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }

    It 'decomposes a project into multiple children and waits for all to complete' {
        $tempDir = Join-Path $TestDrive 'pondengine-project-multi'
        foreach ($sub in @('Tasks/Code','Tasks/Review','Tasks/Audit','Tasks/QA','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed','Tasks/Project','Tasks/ProjectReview')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $planName = '2026-08-26-e2e-project.md'
        $planContent = @"
# E2E Project Plan
**Status**: ready
**Scope**: test
**Challenge**: Local
**Children**: child-a, child-b
"@
        $planContent | Set-Content -LiteralPath (Join-Path $tempDir "Tasks/Project/$planName") -Encoding utf8 -NoNewline

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 8 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Complete/$planName" | Should -Exist
            Join-Path $tempDir "Tasks/Project/$planName" | Should -Not -Exist
            Join-Path $tempDir "Tasks/Failed/$planName" | Should -Not -Exist
            $children = Get-ChildItem -Path (Join-Path $tempDir 'Tasks/Complete') -Filter '*-child-*.md'
            $children.Count | Should -Be 2
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }
}

Describe 'Pond archive task' -Tag 'PondEngine', 'Regression-Only' {
    It 'archives plans older than the configured age and leaves recent plans' {
        $tempDir = Join-Path $TestDrive 'pondengine-archive'
        foreach ($sub in @('Tasks/Code','Tasks/Review','Tasks/Audit','Tasks/QA','Tasks/Complete','Tasks/Archive','Tasks/Working','Tasks/Paused','Tasks/Failed','Tasks/Project','Tasks/ProjectReview')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $oldPlan = '2026-08-01-old-plan.md'
        $newPlan = '2026-08-26-new-plan.md'
        $oldContent = "# Old Plan`n**Status**: complete`n"
        $newContent = "# New Plan`n**Status**: complete`n"
        $oldContent | Set-Content -LiteralPath (Join-Path $tempDir "Tasks/Complete/$oldPlan") -Encoding utf8 -NoNewline
        $newContent | Set-Content -LiteralPath (Join-Path $tempDir "Tasks/Complete/$newPlan") -Encoding utf8 -NoNewline
        (Get-Item -LiteralPath (Join-Path $tempDir "Tasks/Complete/$oldPlan")).LastWriteTime = (Get-Date).AddDays(-10)

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Complete/$oldPlan" | Should -Not -Exist
            Join-Path $tempDir "Tasks/Complete/$newPlan" | Should -Exist
            $archives = Get-ChildItem -Path (Join-Path $tempDir 'Tasks/Archive') -File | Where-Object { $_.Extension -in '.zip', '.7z' }
            $archives.Count | Should -BeGreaterThan 0
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }
}

Describe 'Pond connascence helpers' -Tag 'PondEngine', 'Regression-Only' {
    It 'extracts namespace from a plan filename' {
        & (Get-Module SalmonRun.PondEngine) { Get-PondFileNamespace -FileName '2026-08-25-transfer-salmon-orchestrator-to-salmon-run.md' } | Should -Be 'transfer-salmon-orchestrator-to-salmon-run'
        & (Get-Module SalmonRun.PondEngine) { Get-PondFileNamespace -FileName 'ns-test-1-task.md' } | Should -Be 'ns-test'
        & (Get-Module SalmonRun.PondEngine) { Get-PondFileNamespace -FileName 'orphan.md' } | Should -Be 'ungrouped'
    }

    It 'groups files by namespace' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "connascence-$(Get-Random)") -Force
        try {
            $null = New-Item -ItemType File -Path (Join-Path $td '2026-08-25-a-1.md') -Force
            $null = New-Item -ItemType File -Path (Join-Path $td '2026-08-25-a-2.md') -Force
            $null = New-Item -ItemType File -Path (Join-Path $td 'b-standalone.md') -Force
            $groups = & (Get-Module SalmonRun.PondEngine) { param($d) Get-PondNamespaceGroups -Directory $d } $td
            $groups | Should -HaveCount 2
            ($groups | Where-Object { $_.Namespace -eq 'a' }).Files.Count | Should -Be 2
            ($groups | Where-Object { $_.Namespace -eq 'b-standalone' }).Files.Count | Should -Be 1
        } finally {
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Pond rescue' -Tag 'PondEngine', 'Regression-Only' {
    It 'rescues stale files from Working to Code' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "rescue-$(Get-Random)") -Force
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $td 'Working') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $td 'Code') -Force
            $file = Join-Path $td 'Working/stale.md'
            "# plan" | Set-Content -LiteralPath $file -Encoding utf8 -NoNewline
            (Get-Item $file).LastWriteTime = (Get-Date).AddSeconds(-600)

            $result = & (Get-Module SalmonRun.PondEngine) { param($s,$t) Invoke-PondRescue -SourceDir $s -TargetDir $t -StaleThresholdSeconds 300 } (Join-Path $td 'Working') (Join-Path $td 'Code')
            $result.Rescued | Should -Be 1
            Join-Path $td 'Code/stale.md' | Should -Exist
            $file | Should -Not -Exist
        } finally {
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not rescue fresh files' {
        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "rescue-$(Get-Random)") -Force
        try {
            $null = New-Item -ItemType Directory -Path (Join-Path $td 'Working') -Force
            $null = New-Item -ItemType Directory -Path (Join-Path $td 'Code') -Force
            $file = Join-Path $td 'Working/fresh.md'
            "# plan" | Set-Content -LiteralPath $file -Encoding utf8 -NoNewline

            $result = & (Get-Module SalmonRun.PondEngine) { param($s,$t) Invoke-PondRescue -SourceDir $s -TargetDir $t -StaleThresholdSeconds 300 } (Join-Path $td 'Working') (Join-Path $td 'Code')
            $result.Rescued | Should -Be 0
            $file | Should -Exist
        } finally {
            Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rescues stale failed plans back to Code' {
        $tempDir = Join-Path $TestDrive 'rescue-failed'
        foreach ($sub in @('Tasks/Code','Tasks/Failed')) {
            $null = New-Item -ItemType Directory -Path (Join-Path $tempDir $sub) -Force
        }

        $plan = '2026-08-26-stale-failed.md'
        $content = "# Plan`n**Status**: ready`n**Scope**: test`n**Challenge**: Local`n"
        $content | Set-Content -LiteralPath (Join-Path $tempDir "Tasks/Failed/$plan") -Encoding utf8 -NoNewline
        (Get-Item (Join-Path $tempDir "Tasks/Failed/$plan")).LastWriteTime = (Get-Date).AddSeconds(-90)

        $saved = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $tempDir
            Start-PondEngine -RepoDir $tempDir -MaxIterations 1 -PollIntervalSeconds 0 -SubprocessTimeoutMinutes 1
            Join-Path $tempDir "Tasks/Failed/$plan" | Should -Not -Exist
            $found = @(Get-ChildItem -Path (Join-Path $tempDir 'Tasks') -Recurse -Filter $plan -File | Select-Object -ExpandProperty FullName)
            $found.Count | Should -Be 1
        } finally {
            $env:SALMON_RUN_HOME = $saved
        }
    }
}

Describe 'Pond public executor safety' -Tag 'PondEngine', 'Regression-Only' {
    It 'does not leak private hostnames, internal paths, or credential values in executor scripts' {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $executorsDir = Join-Path $repoRoot 'Modules/SalmonRun.PondEngine/Executors'
        $privatePatterns = @(
            'salmon-orchestrator'
            'mcp_opencode'
            'OC_STREAM'
            'OC_RESERVATION'
            'OC_PROJECT_ROOT'
            'Get-SkillsRoot'
            'New-AgentWorktree'
            'Write-OrchestratorLog\s+".*platform.*:'
            'http://mcp_'
        )
        $files = Get-ChildItem -Path $executorsDir -Filter '*.ps1' -File
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($pattern in $privatePatterns) {
                $content -match $pattern | Should -Be $false -Because "file $($file.Name) should not contain '$pattern'"
            }
        }
    }
}

Describe 'Pond capacity' -Tag 'PondEngine', 'Regression-Only' {
    It 'allows work when crash history is empty' {
        $result = & (Get-Module SalmonRun.PondEngine) { Get-PondCapacity -CrashHistory $null }
        $result | Should -Be $true
    }

    It 'throttles when recent crashes exceed threshold' {
        $crashes = [System.Collections.Generic.List[datetime]]::new()
        $now = Get-Date
        for ($i = 0; $i -lt 3; $i++) { $crashes.Add($now.AddSeconds(-$i)) }
        $result = & (Get-Module SalmonRun.PondEngine) { param($c) Get-PondCapacity -CrashHistory $c -MaxCrashesPerWindow 3 } $crashes
        $result | Should -Be $false
    }

    It 'returns increasing backoff delay with more crashes' {
        $crashes = [System.Collections.Generic.List[datetime]]::new()
        for ($i = 0; $i -lt 3; $i++) { $crashes.Add((Get-Date).AddMinutes(-$i)) }
        $delay = & (Get-Module SalmonRun.PondEngine) { param($c) Get-PondCrashThrottleDelay -CrashHistory $c } $crashes
        $delay | Should -BeGreaterThan 0
    }
}

Describe 'OpenCode executor command' -Tag 'PondEngine', 'Regression-Only' {
    It 'produces an opencode-go command without hardcoded private paths' {
        $srExecProfile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Complex' }
        $srExecProfile.Provider | Should -Be 'opencode-go'

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'coder' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'opencode run'
        $cmd.Command | Should -Match $srExecProfile.Model
        $cmd.Command | Should -Match $srExecProfile.Effort
        $cmd.Command | Should -Match '--variant'
        $cmd.Command | Should -Match '--auto'

        $homePattern = [regex]::Escape(('C:', 'Users', 'RDP') -join [IO.Path]::DirectorySeparatorChar)
        $privatePatterns = @(
            'salmon' + '-orchestrator'
            $homePattern
            'OC_STREAM'
            'OC_RESERVATION'
            'OC_PROJECT_ROOT'
        )
        $commandText = $cmd.Command
        $startInfoText = $cmd.StartInfo.ArgumentList -join ' '
        foreach ($pattern in $privatePatterns) {
            $commandText | Should -Not -Match $pattern
            $startInfoText | Should -Not -Match $pattern
        }

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain '-Provider'
        $cmd.StartInfo.ArgumentList | Should -Contain 'opencode-go'
    }

    It 'produces an opencode (Zen) command' {
        $srExecProfile = [PondExecutionProfile]::new()
        $srExecProfile.Provider = 'opencode'
        $srExecProfile.Cli = 'opencode'
        $srExecProfile.Model = 'opencode/hy3-free'
        $srExecProfile.Effort = 'max'
        $srExecProfile.ExecutorFile = 'Opencode'
        $srExecProfile.Credentials = @('OPENCODE_GO_KEY')

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'reviewer' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Review\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'opencode run'
        $cmd.Command | Should -Match 'opencode/hy3-free'
        $cmd.Command | Should -Match '--variant'
        $cmd.Command | Should -Match '--auto'

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain 'opencode'
        $cmd.StartInfo.ArgumentList | Should -Contain 'opencode/hy3-free'
        $cmd.StartInfo.ArgumentList | Should -Contain 'reviewer'
        $cmd.Credentials | Should -Contain 'OPENCODE_GO_KEY'
    }
}

Describe 'OpenCode executor adapter' -Tag 'PondEngine', 'Regression-Only' {
    BeforeEach {
        $script:OpencodeArgs = $null
    }

    It 'parses parameters and builds the correct opencode command' {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $opencode = Join-Path $repoRoot 'Modules/SalmonRun.PondEngine/Executors/Opencode.ps1'

        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "opencode-adapter-$(Get-Random)") -Force
        $plan = Join-Path $td 'plan.md'
        @'
# Test plan

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $salmonHome = Join-Path $TestDrive 'opencode-home'
        $null = New-Item -ItemType Directory -Path $salmonHome -Force
        'OPENCODE_GO_KEY=test-key' | Set-Content -LiteralPath (Join-Path $salmonHome '.env') -Encoding utf8 -NoNewline

        $savedSalmonHome = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $salmonHome

            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, $NoNewWindow, $PassThru)
                $script:OpencodeArgs = $ArgumentList
                return [PSCustomObject]@{
                    HasExited = $true
                    ExitCode  = 0
                    Id        = 1234
                }
            }

            . $opencode -Role 'coder' -LanePath $td -RepoDir $td -Provider 'opencode-go' -Model 'opencode-go/mimo-v2.5' -Effort 'max' -TimeoutMinutes 5 -PlanFiles @($plan)
            $result = Invoke-OpencodeProvider

            $result | Should -Be 0
            $script:OpencodeArgs | Should -Not -BeNullOrEmpty
            $script:OpencodeArgs | Should -Contain 'opencode-go/mimo-v2.5'
            $script:OpencodeArgs | Should -Contain '--model'
            $script:OpencodeArgs | Should -Contain '--variant'
            $script:OpencodeArgs | Should -Contain 'max'
            $script:OpencodeArgs | Should -Contain '--auto'
            $script:OpencodeArgs | Should -Contain '-f'
            $script:OpencodeArgs | Should -Contain $plan

            $log = Get-PlanPondLog -PlanPath $plan
            $log | Should -HaveCount 2
            $log.action | Should -Contain 'spawn'
            $log.action | Should -Contain 'external-complete'
        } finally {
            $env:SALMON_RUN_HOME = $savedSalmonHome
        }
    }

    It 'runs without OPENCODE_GO_KEY for free-tier models' {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $opencode = Join-Path $repoRoot 'Modules/SalmonRun.PondEngine/Executors/Opencode.ps1'

        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "opencode-missing-$(Get-Random)") -Force
        $plan = Join-Path $td 'plan.md'
        @'
# Test plan

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $savedSalmonHome = $env:SALMON_RUN_HOME
        $savedKey = $env:OPENCODE_GO_KEY
        try {
            $env:SALMON_RUN_HOME = $td
            $env:OPENCODE_GO_KEY = $null

            Mock Start-Process -MockWith {
                return [PSCustomObject]@{ HasExited = $true; ExitCode = 0; Id = 1234 }
            }

            . $opencode -Role 'coder' -LanePath $td -RepoDir $td -Provider 'opencode' -Model 'opencode/hy3-free' -Effort 'max' -PlanFiles @($plan)
            $result = Invoke-OpencodeProvider

            $result | Should -Be 0
        } finally {
            $env:SALMON_RUN_HOME = $savedSalmonHome
            $env:OPENCODE_GO_KEY = $savedKey
        }
    }
}

Describe 'OpenCode Go DeepSeek command' -Tag 'PondEngine', 'Regression-Only' {
    It 'produces an OpenCode Go command for Complex without hardcoded private paths' {
        $srExecProfile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Complex' }
        $srExecProfile.Provider | Should -Be 'opencode-go'

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'coder' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'opencode run'
        $cmd.Command | Should -Match $srExecProfile.Model
        $cmd.Command | Should -Match '--auto'

        $homePattern = [regex]::Escape(('C:', 'Users', 'RDP') -join [IO.Path]::DirectorySeparatorChar)
        $worktreePattern = 'worktree' + '\.' + 'ca'
        $privatePatterns = @(
            'salmon' + '-orchestrator'
            $homePattern
            $worktreePattern
        )
        $commandText = $cmd.Command
        $startInfoText = $cmd.StartInfo.ArgumentList -join ' '
        foreach ($pattern in $privatePatterns) {
            $commandText | Should -Not -Match $pattern
            $startInfoText | Should -Not -Match $pattern
        }

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain '-Provider'
        $cmd.StartInfo.ArgumentList | Should -Contain 'opencode-go'
        $cmd.Credentials | Should -Contain 'OPENCODE_GO_KEY'
    }

    It 'produces an OpenCode Go Frontier command' {
        $srExecProfile = [PondExecutionProfile]::new()
        $srExecProfile.Provider = 'opencode-go'
        $srExecProfile.Cli = 'opencode'
        $srExecProfile.Model = 'opencode-go/deepseek-v4-pro'
        $srExecProfile.Effort = 'max'
        $srExecProfile.ExecutorFile = 'Opencode'
        $srExecProfile.Credentials = @('OPENCODE_GO_KEY')

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'reviewer' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Review\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'opencode run'
        $cmd.Command | Should -Match 'opencode-go/deepseek-v4-pro'

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain 'opencode-go'
        $cmd.StartInfo.ArgumentList | Should -Contain 'opencode-go/deepseek-v4-pro'
        $cmd.StartInfo.ArgumentList | Should -Contain 'reviewer'
        $cmd.Credentials | Should -Contain 'OPENCODE_GO_KEY'
    }
}

Describe 'External executor command routing' -Tag 'PondEngine', 'Regression-Only' {
    It 'produces a devin command' {
        $srExecProfile = [PondExecutionProfile]::new()
        $srExecProfile.Provider = 'devin'
        $srExecProfile.Cli = 'devin'
        $srExecProfile.Model = 'swe-1-7'
        $srExecProfile.Effort = 'medium'
        $srExecProfile.ExecutorFile = 'Devin'
        $srExecProfile.Credentials = @('DEVIN_API_KEY')

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'planner' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'devin'
        $cmd.Command | Should -Match 'swe-1-7'

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain 'devin'
        $cmd.StartInfo.ArgumentList | Should -Contain 'swe-1-7'
        $cmd.StartInfo.ArgumentList | Should -Contain 'planner'
        $cmd.Credentials | Should -Contain 'DEVIN_API_KEY'
    }

    It 'produces a dsh/openrouter command' {
        $srExecProfile = [PondExecutionProfile]::new()
        $srExecProfile.Provider = 'openrouter'
        $srExecProfile.Cli = 'dsh'
        $srExecProfile.Model = 'deepseek-v4-pro'
        $srExecProfile.Effort = 'max'
        $srExecProfile.ExecutorFile = 'Dsh'
        $srExecProfile.Credentials = @('OPENROUTER_API_KEY')

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'auditor' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'dsh --profile headless'

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain 'openrouter'
        $cmd.StartInfo.ArgumentList | Should -Contain 'deepseek-v4-pro'
        $cmd.StartInfo.ArgumentList | Should -Contain 'auditor'
        $cmd.Credentials | Should -Contain 'OPENROUTER_API_KEY'
    }

    It 'produces a dsh/deepinfra command' {
        $srExecProfile = [PondExecutionProfile]::new()
        $srExecProfile.Provider = 'deepinfra'
        $srExecProfile.Cli = 'dsh'
        $srExecProfile.Model = 'deepseek-v4-flash'
        $srExecProfile.Effort = 'medium'
        $srExecProfile.ExecutorFile = 'Dsh'
        $srExecProfile.Credentials = @('DEEPINFRA_API_KEY')

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'qa' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'dsh --profile headless'

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain 'deepinfra'
        $cmd.StartInfo.ArgumentList | Should -Contain 'deepseek-v4-flash'
        $cmd.StartInfo.ArgumentList | Should -Contain 'qa'
        $cmd.Credentials | Should -Contain 'DEEPINFRA_API_KEY'
    }

    It 'produces a codex command' {
        $srExecProfile = [PondExecutionProfile]::new()
        $srExecProfile.Provider = 'codex'
        $srExecProfile.Cli = 'codex'
        $srExecProfile.Model = 'gpt-5.6-luna'
        $srExecProfile.Effort = 'low'
        $srExecProfile.ExecutorFile = 'Codex'
        $srExecProfile.Credentials = @('OPENAI_API_KEY')

        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -srExecProfile $p -Role 'coder' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $srExecProfile

        $cmd.Command | Should -Match 'codex exec'
        $cmd.Command | Should -Match 'gpt-5.6-luna'
        $cmd.Command | Should -Match 'model_reasoning_effort=low'

        $cmd.StartInfo.FilePath | Should -BeIn @('pwsh', 'powershell')
        $cmd.StartInfo.ArgumentList | Should -Contain 'gpt-5.6-luna'
        $cmd.StartInfo.ArgumentList | Should -Contain 'codex'
        $cmd.StartInfo.ArgumentList | Should -Contain 'low'
        $cmd.Credentials | Should -Contain 'OPENAI_API_KEY'
    }
}

Describe 'External executor adapter mocks' -Tag 'PondEngine', 'Regression-Only' {

    It 'Devin adapter parses parameters and spawns the devin CLI' {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $scriptPath = Join-Path $repoRoot 'Modules/SalmonRun.PondEngine/Executors/Devin.ps1'

        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ext-adapter-devin') -Force
        $plan = Join-Path $td 'plan.md'
        @'
# Test plan

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $salmonHome = Join-Path $TestDrive 'devin-home'
        $null = New-Item -ItemType Directory -Path $salmonHome -Force
        'DEVIN_API_KEY=test-key' | Set-Content -LiteralPath (Join-Path $salmonHome '.env') -Encoding utf8 -NoNewline

        $savedSalmonHome = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $salmonHome

            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, $NoNewWindow, $PassThru)
                $script:ExtArgs = $ArgumentList
                return [PSCustomObject]@{
                    HasExited = $true
                    ExitCode  = 0
                    Id        = 1234
                }
            }

            . $scriptPath -Role 'coder' -LanePath $td -RepoDir $td -Provider 'devin' -Model 'swe-1-7' -Effort 'medium' -TimeoutMinutes 5 -PlanFiles @($plan)

            $result = Invoke-DevinProvider

            $result | Should -Be 0
            $script:ExtArgs | Should -Not -BeNullOrEmpty
            $script:ExtArgs | Should -Contain '--prompt-file'
            $script:ExtArgs | Should -Contain '-p'
            $script:ExtArgs | Should -Contain 'swe-1-7'

            $log = Get-PlanPondLog -PlanPath $plan
            $log | Should -HaveCount 2
            $log.action | Should -Contain 'spawn'
            $log.action | Should -Contain 'external-complete'
        } finally {
            $env:SALMON_RUN_HOME = $savedSalmonHome
        }
    }

    $dshTestCases = @(
        @{
            Provider    = 'dsh'
            Model       = 'deepseek-v4-flash'
            Effort      = 'max'
            Credential  = 'DEEPSEEK_API_KEY'
        }
        @{
            Provider    = 'openrouter'
            Model       = 'deepseek-v4-flash'
            Effort      = 'max'
            Credential  = 'OPENROUTER_API_KEY'
        }
        @{
            Provider    = 'deepinfra'
            Model       = 'deepseek-v4-flash'
            Effort      = 'medium'
            Credential  = 'DEEPINFRA_API_KEY'
        }
    )

    It 'DSH adapter parses parameters and spawns dsh for <Provider>' -TestCases $dshTestCases {
        param($Provider, $Model, $Effort, $Credential)

        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $scriptPath = Join-Path $repoRoot 'Modules/SalmonRun.PondEngine/Executors/Dsh.ps1'

        $td = New-Item -ItemType Directory -Path (Join-Path $TestDrive "ext-adapter-dsh-$Provider-$(Get-Random)") -Force
        $plan = Join-Path $td 'plan.md'
        @'
# Test plan

**PondLog**

```json
[]
```
'@ | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

        $salmonHome = Join-Path $TestDrive "dsh-$Provider-home"
        $null = New-Item -ItemType Directory -Path $salmonHome -Force
        "$Credential=test-key" | Set-Content -LiteralPath (Join-Path $salmonHome '.env') -Encoding utf8 -NoNewline

        $savedSalmonHome = $env:SALMON_RUN_HOME
        try {
            $env:SALMON_RUN_HOME = $salmonHome

            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, $NoNewWindow, $PassThru)
                $script:ExtArgs = $ArgumentList
                return [PSCustomObject]@{
                    HasExited = $true
                    ExitCode  = 0
                    Id        = 1234
                }
            }

            . $scriptPath -Role 'coder' -LanePath $td -RepoDir $td -Provider $Provider -Model $Model -Effort $Effort -TimeoutMinutes 5 -PlanFiles @($plan)

            $result = Invoke-DshProvider

            $result | Should -Be 0
            $script:ExtArgs | Should -Not -BeNullOrEmpty
            $script:ExtArgs | Should -Contain '--profile'
            $script:ExtArgs | Should -Contain 'headless'
            $script:ExtArgs | Should -Contain '--patch'

            $log = Get-PlanPondLog -PlanPath $plan
            $log | Should -HaveCount 2
            $log.action | Should -Contain 'spawn'
            $log.action | Should -Contain 'external-complete'
        } finally {
            $env:SALMON_RUN_HOME = $savedSalmonHome
        }
    }
}


