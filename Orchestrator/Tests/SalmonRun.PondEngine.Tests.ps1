#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Orchestrator' 'Modules'

    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }

    # Ensure a clean module load in case other test files have left stale
    # orchestrator/pond state in the same session.
    Remove-Module 'SalmonRun.PondEngine', 'SalmonRun.Paths', 'SalmonRun.Constants', 'SalmonRun.Core', 'SalmonRun.AgentLifecycle' -Force -ErrorAction SilentlyContinue

    $script:PondEnginePsd1 = Join-Path $__ModulesDir 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psd1'
    Import-Module $script:PondEnginePsd1 -Force -ErrorAction Stop
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
        $stream.Lanes.Count | Should -Be 6
    }

    It 'has three coder lanes, one reviewer, one auditor, one qa' {
        $stream = New-PondStream -Id 'stream-1' -Branch 'main' -Path 'C:\temp\repo'
        $roles = $stream.Lanes.Values | Group-Object Role | ForEach-Object { @{ $_.Name = $_.Count } }
        $coder = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'coder' }).Count
        $reviewer = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'reviewer' }).Count
        $auditor = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'auditor' }).Count
        $qa = ($stream.Lanes.Values | Where-Object { $_.Role -eq 'qa' }).Count
        $coder | Should -Be 3
        $reviewer | Should -Be 1
        $auditor | Should -Be 1
        $qa | Should -Be 1
    }
}

Describe 'Pond executor registry' -Tag 'PondEngine', 'Regression-Only' {
    It 'resolves a Daily profile from the model-router catalog' {
        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Daily' }
        $profile | Should -Not -BeNullOrEmpty
        $profile.Harness | Should -Not -BeNullOrEmpty
        $profile.Provider | Should -Not -BeNullOrEmpty
        $profile.Model | Should -Not -BeNullOrEmpty
        $profile.Effort | Should -Not -BeNullOrEmpty
        $profile.Cli | Should -Not -BeNullOrEmpty
        $profile.ExecutorFile | Should -Not -BeNullOrEmpty
    }

    It 'resolves different models for each tier' {
        $flash = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Flash' }
        $frontier = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Frontier' }
        $flash.Model | Should -Not -Be $frontier.Model -Because 'Flash and Frontier should route to different models'
    }

    It 'produces a runnable executor command from a profile' {
        $profile = & (Get-Module SalmonRun.PondEngine) { Resolve-PondExecutionProfile -Tier 'Daily' }
        $cmd = & (Get-Module SalmonRun.PondEngine) { param($p) Get-PondExecutorCommand -Profile $p -Role 'coder' -RepoDir 'C:\temp\repo' -PlanFiles @('C:\temp\repo\Tasks\Code\plan.md') } $profile
        $cmd.ExecutorPath | Should -Exist
        $cmd.Command | Should -Match "work-coder-once"
        $cmd.Command | Should -Match $profile.Model
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
