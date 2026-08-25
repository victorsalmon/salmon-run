#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

BeforeAll {
    $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    $__modulesDir = [System.IO.Path]::Combine($__repoRoot, "Orchestrator", "Modules")

    $script:OrchestrateModuleDir = Join-Path $__modulesDir "SalmonRun.Orchestrate"
    $script:OrchestratePsd1 = Join-Path $script:OrchestrateModuleDir "SalmonRun.Orchestrate.psd1"
    $script:OrchestratePublic = Join-Path $script:OrchestrateModuleDir "Public"
    $script:OrchestratePrivate = Join-Path $script:OrchestrateModuleDir "Private"
    $script:OrchestrateExecutors = Join-Path $script:OrchestrateModuleDir "Executors"

    # Stub functions that Private scripts depend on
    function Get-InterclawRepoRoot { return $__repoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
    function Write-OrchestratorLogSafe { param([string]$Message, [string]$Level) }
    function Write-OrchestratorHeartbeat { param([string]$HeartbeatFile) }
    function Prepend-StreamLog {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
        param([string]$StreamDir, [string]$Entry)
    }
    function Write-OrchestratorError { param([string]$Op, [string]$Message, [string]$Stack, [int]$Iteration) }
    function Write-FleetStatusTable { }
    function Write-IterationStatus { param($Counts, [int]$Iteration, [int]$MaxIterations, [int]$TotalProcessed, [int]$TotalCrashed, $SessionStart) }
    function Clear-IterationEnvironment { param([int]$Iteration) }
    function Test-OpenCodeAvailable { return $null }
    function Get-FileNamespace { param([string]$FileName) }
    function Initialize-OrchestratorPidLock { param([string]$PidLockFile, [int]$InstanceId); return $true }
    function Invoke-OrchestratorStartupRescue { param([string]$RepoDir, [string]$HeartbeatFile, [int]$SubprocessTimeoutMinutes) }
    function Clear-StaleOrchestratorFiles { param([string]$RepoDir, [int]$InstanceId, [int]$SubprocessTimeoutMinutes) }
    function Get-TaskCounts { return @{ CoderWorkload = 0; ReviewerWorkload = 0; RootCoder = 0; Review = 0; Working = 0 } }
    function Invoke-InterIterationStaleSweep { param([string]$RepoDir) }
    function Invoke-PeriodicCleanup { param([int]$Iteration, [string]$RepoDir) }
    function Invoke-StallDetection { param($Counts, $PreviousCounts, [int]$StallCount, [int]$MaxStall, [int]$Iteration, [int]$InstanceId); return @{ StallLimitReached = $false; NewStallCount = 0 } }
    function Invoke-ReadFilesystemState { param([string]$RepoDir); return @{ activeStreams = @{} } }
    function Invoke-ReconcileState { param([string]$RepoDir, $ActiveStreams, $BusyNamespaces, $UsedNamespaces); return @() }
    function Clear-UsedNamepacesForFiles { param([string]$RepoDir, $UsedNamespaces, [string]$NamespaceFilter) }
    function Get-DynamicCapacity { param([int]$CodeParallelCount, [int]$ReviewerParallelCount, [int]$CoderWorkload, [int]$ReviewerWorkload, [int]$ActiveCoder, [int]$ActiveReviewer); return @{ CapacityCoder = 3; CapacityReviewer = 6 } }
    function Get-CrashThrottleCapacity { param($CrashHistory, [int]$DefaultCapacity); return $DefaultCapacity }
    function Get-NextStreamId { param([string]$WorkingDir); return 1 }
    function Add-FileToStream { param([string]$StreamDir, [string]$SourcePath) }
    function Write-AtomicJson { param([string]$Path, [object]$InputObject) }
    function Start-StreamCoder { param([string]$StreamId, [string]$StreamDir, [string]$RepoDir, [string]$OpencodePath, [int]$InstanceId, [string]$Role, [switch]$UseWorktrees, [string]$Namespace) }
    function Remove-Stream { param([string]$StreamDir, [string]$AgentId) }
    function Rescue-OrphanedLocks {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
        param([string]$RepoDir)
    }
    function Get-ExecutorTaskStatus { param($Task) }
    function Stop-ExecutorTask { param($Task) }
    function Test-IsFatalError { param($Counts, $CgResult); return $false }
    function Invoke-QuarantineFile { param([string]$FilePath, [string]$RepoDir, [string]$Reason) }
    function Handle-OrphanStatus {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
        param($File, $Agent, [string]$RepoDir, [string]$RescueKind)
    }
    function Get-FileRetryBudget { return $null }
    function Increment-FileRetry {
        [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
        param([string]$FileName, [string]$StreamId, [int]$ExitCode); return 1
    }
    function Test-FileExceededRetryBudget { param([string]$FileName); return $false }
    function Reset-FileRetry { param([string]$FileName) }
    function Stop-ProcessTree { param([int]$ProcessId, [switch]$Force) }
    function Write-AgentPidFile { param([string]$AgentId) }
    function Write-AgentHeartbeat { param([string]$AgentId) }
    function Get-BackoffDelay { param([int]$Attempt = 0, [int]$BaseMs = 1000, [int]$CapMs = 60000); return $BaseMs }
    function Write-AtomicFile { param([string]$Path, [object]$Content) }
    function Clear-StaleRetryBudgetEntries { param([string]$RepoDir) }
    function Get-AvailableContainerAgent { return $null }
    function Initialize-Executor { }
    function Disconnect-Executor { }
    function Get-OpenCodeGoApiKey { }
}

Describe "SalmonRun.Orchestrate Module Manifest" -Tag "Orchestrate", "Regression-Only" {

    It "psd1 file exists" {
        Test-Path $script:OrchestratePsd1 | Should -Be $true
    }

    It "exports exactly 4 functions" {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratePsd1
        $manifest.FunctionsToExport.Count | Should -Be 4
        $manifest.FunctionsToExport | Should -Contain "Start-Orchestrator"
        $manifest.FunctionsToExport | Should -Contain "Stop-Orchestrator"
        $manifest.FunctionsToExport | Should -Contain "Get-OrchestratorStatus"
        $manifest.FunctionsToExport | Should -Contain "Get-OrchestratorQueue"
    }

    It "has a valid GUID" {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratePsd1
        { [guid]::Parse($manifest.GUID) } | Should -Not -Throw
    }

    It "declares SalmonRun.Paths, SalmonRun.Core and SalmonRun.AgentLifecycle as RequiredModules" {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratePsd1
        $manifest.RequiredModules.Count | Should -Be 3
        $manifest.RequiredModules[0].ModuleName | Should -Be "SalmonRun.Paths"
        $manifest.RequiredModules[1].ModuleName | Should -Be "SalmonRun.Core"
        $manifest.RequiredModules[2].ModuleName | Should -Be "SalmonRun.AgentLifecycle"
    }
}

Describe "Clear-UsedNamepacesForFiles function (State.ps1)" -Tag "Orchestrate", "Regression-Only" {
    It "can be dot-sourced without error" {
        { . (Join-Path $script:OrchestratePrivate "State.ps1") } | Should -Not -Throw
    }

    It "defines the Clear-UsedNamepacesForFiles function" {
        . (Join-Path $script:OrchestratePrivate "State.ps1")
        Get-Command Clear-UsedNamepacesForFiles -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "Start-Orchestrator function" -Tag "Orchestrate" {

    It "can be dot-sourced without error" {
        { . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1") } | Should -Not -Throw
    }

    It "defines the Start-Orchestrator function after sourcing" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        Get-Command Start-Orchestrator -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "has mandatory Executor parameter with ValidateSet 'local', 'local-platform', 'platform'" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('Executor') | Should -Be $true
        $validateSet = ($cmd.Parameters['Executor'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        $validateSet | Should -Not -BeNullOrEmpty
        $validateSet.ValidValues | Should -Contain "local"
        $validateSet.ValidValues | Should -Contain "local-platform"
        $validateSet.ValidValues | Should -Contain "platform"
    }

    It "has MaxIterations parameter with ValidateRange 1-360" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('MaxIterations') | Should -Be $true
        $range = ($cmd.Parameters['MaxIterations'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $range | Should -Not -BeNullOrEmpty
        $range.MinRange | Should -Be 1
        $range.MaxRange | Should -Be 360
    }

    It "has SubprocessTimeoutMinutes parameter with ValidateRange 1-120" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('SubprocessTimeoutMinutes') | Should -Be $true
        $range = ($cmd.Parameters['SubprocessTimeoutMinutes'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $range.MinRange | Should -Be 1
        $range.MaxRange | Should -Be 120
    }

    It "has CodeParallelCount and ReviewerParallelCount parameters" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('CodeParallelCount') | Should -Be $true
        $cmd.Parameters.ContainsKey('ReviewerParallelCount') | Should -Be $true
        $rangeCode = ($cmd.Parameters['CodeParallelCount'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $rangeReview = ($cmd.Parameters['ReviewerParallelCount'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $rangeCode.MinRange | Should -Be 1
        $rangeCode.MaxRange | Should -Be 20
        $rangeReview.MinRange | Should -Be 1
        $rangeReview.MaxRange | Should -Be 20
    }

    It "has Detach, Resume, NoAuditPrompt switches" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('Detach') | Should -Be $true
        $cmd.Parameters.ContainsKey('Resume') | Should -Be $true
        $cmd.Parameters.ContainsKey('NoAuditPrompt') | Should -Be $true
        $cmd.Parameters['Detach'].ParameterType.Name | Should -Be "SwitchParameter"
    }

    It "has InstanceId parameter defaulting to 1" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('InstanceId') | Should -Be $true
        $range = ($cmd.Parameters['InstanceId'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $range.MinRange | Should -Be 1
        $range.MaxRange | Should -Be 100
    }

    It "has IdleTimeoutMinutes parameter with ValidateRange 1-480" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('IdleTimeoutMinutes') | Should -Be $true
        $range = ($cmd.Parameters['IdleTimeoutMinutes'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $range.MinRange | Should -Be 1
        $range.MaxRange | Should -Be 480
    }

    It "has PollIntervalSeconds parameter with ValidateRange 10-600" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $cmd = Get-Command Start-Orchestrator
        $cmd.Parameters.ContainsKey('PollIntervalSeconds') | Should -Be $true
        $range = ($cmd.Parameters['PollIntervalSeconds'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] })
        $range.MinRange | Should -Be 10
        $range.MaxRange | Should -Be 600
    }

    It "has Executor defaulting to 'local'" {
        . (Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1")
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:OrchestratePublic "Start-Orchestrator.ps1"), [ref]$null, [ref]$null)
        $paramBlock = $ast.Find({ $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true)
        $execParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Executor' }
        $execParam.DefaultValue.Extent.Text | Should -Match '"local"'
    }
}

Describe "SalmonRun.Orchestrate Executor scripts" -Tag "Orchestrate" {

    It "Local executor exists and defines Start-StreamCoder" {
        $localPath = Join-Path $script:OrchestrateExecutors "Local.ps1"
        Test-Path $localPath | Should -Be $true
        . $localPath
        Get-Command Start-StreamCoder -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "Platform executor exists" {
        $platformPath = Join-Path $script:OrchestrateExecutors "Platform.ps1"
        Test-Path $platformPath | Should -Be $true
    }

    It "LocalPlatform executor exists" {
        $localPlatformPath = Join-Path $script:OrchestrateExecutors "local-platform.ps1"
        Test-Path $localPlatformPath | Should -Be $true
    }
}

Describe "Executor readiness checks" -Tag "Orchestrate" {

    BeforeEach {
        $script:localPath = Join-Path $script:OrchestrateExecutors "Local.ps1"
        $script:localPlatformPath = Join-Path $script:OrchestrateExecutors "local-platform.ps1"
        $script:platformPath = Join-Path $script:OrchestrateExecutors "Platform.ps1"
    }

    It "Local.Initialize-Executor detects missing opencode CLI" {
        Mock Test-OpenCodeAvailable { return $null }
        . $script:localPath
        { Initialize-Executor } | Should -Throw
    }

    It "Local.Initialize-Executor succeeds when CLI found" {
        Mock Test-OpenCodeAvailable { return "C:\tools\opencode.ps1" }
        . $script:localPath
        { Initialize-Executor } | Should -Not -Throw
    }

    It "local-platform.Initialize-Executor retries on health check failure" {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/api/health" } {
            $callCount = $global:healthCallCount ?? 0
            $global:healthCallCount = $callCount + 1
            if ($callCount -lt 2) { throw "Service unavailable" }
            return @{ status = "ok" }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/session" } {
            return @{ id = "test-session" }
        }
        . $script:localPlatformPath
        { Initialize-Executor } | Should -Not -Throw
    }

    It "local-platform.Initialize-Executor throws after all retries exhausted" {
        Mock Invoke-RestMethod { throw "Service unavailable" }
        . $script:localPlatformPath
        { Initialize-Executor } | Should -Throw
    }

    It "Platform.Initialize-Executor retries on health check failure" {
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/api/health" } {
            $callCount = $global:healthCallCount ?? 0
            $global:healthCallCount = $callCount + 1
            if ($callCount -lt 2) { throw "Service unavailable" }
            return @{ status = "ok" }
        }
        Mock Invoke-RestMethod -ParameterFilter { $Uri -like "*/session" } {
            return @{ id = "test-session" }
        }
        . $script:platformPath
        { Initialize-Executor } | Should -Not -Throw
    }

    It "Platform.Initialize-Executor throws after all retries exhausted" {
        Mock Invoke-RestMethod { throw "Service unavailable" }
        . $script:platformPath
        { Initialize-Executor } | Should -Throw
    }
}

Describe "SalmonRun.Orchestrate accessible via canonical module" -Tag "Orchestrate", "Regression-Only" {

    It "Start-Orchestrator is exported by SalmonRun.Orchestrate manifest" {
        $manifest = Import-PowerShellDataFile -Path $script:OrchestratePsd1
        $manifest.FunctionsToExport | Should -Contain "Start-Orchestrator"
    }
}

Describe "Spawned PID registry" -Tag "Orchestrate", "Process", "Regression" {

    BeforeAll {
        # Dot-source Process.ps1 directly for registry functions
        . (Join-Path $script:OrchestratePrivate "Process.ps1")
        $testRegistry = Join-Path $TestDrive "spawned-pids.json"
        Initialize-SpawnedPidRegistry -RegistryPath $testRegistry
    }

    AfterAll {
        if (Test-Path $testRegistry) { Remove-Item $testRegistry -Force -ErrorAction SilentlyContinue }
    }

    Context "Initialize-SpawnedPidRegistry" {
        It "creates the registry file with empty state" {
            $content = Get-Content $testRegistry -Raw -Encoding utf8
            $content | Should -Not -BeNullOrEmpty
            $parsed = $content | ConvertFrom-Json
            $parsed.pids.Count | Should -Be 0
        }
    }

    Context "Register-SpawnedPid" {
        It "adds a PID to the registry" {
            Register-SpawnedPid -ProcessId 12345 -AgentId "test-stream"
            $pids = Get-SpawnedPids
            $pids | Should -Contain 12345
        }

        It "does not duplicate PIDs" {
            Register-SpawnedPid -ProcessId 12345 -AgentId "test-stream"
            Register-SpawnedPid -ProcessId 12345 -AgentId "test-stream"
            $pids = Get-SpawnedPids
            $pids.Count | Should -Be 1
        }

        It "replaces the prior PID when an agent ID is reused" {
            Register-SpawnedPid -ProcessId 33331 -AgentId "reused-stream"
            Register-SpawnedPid -ProcessId 33332 -AgentId "reused-stream"
            $pids = Get-SpawnedPids
            $pids | Should -Contain 33332
            $pids | Should -Not -Contain 33331
            $registry = Get-Content $testRegistry -Raw | ConvertFrom-Json
            $registry.byAgent.'reused-stream' | Should -Be 33332
        }

        It "accepts multiple PIDs" {
            Register-SpawnedPid -ProcessId 11111 -AgentId "stream-a"
            Register-SpawnedPid -ProcessId 22222 -AgentId "stream-b"
            $pids = Get-SpawnedPids
            $pids | Should -Contain 11111
            $pids | Should -Contain 22222
        }
    }

    Context "Unregister-SpawnedPid" {
        It "removes a PID from the registry" {
            Register-SpawnedPid -ProcessId 99999 -AgentId "to-remove"
            Unregister-SpawnedPid -ProcessId 99999 -AgentId "to-remove"
            $pids = Get-SpawnedPids
            $pids | Should -Not -Contain 99999
        }
    }

    Context "Test-IsSpawnedPid" {
        It "returns true for registered PIDs" {
            Register-SpawnedPid -ProcessId 55555 -AgentId "check-true"
            Test-IsSpawnedPid -ProcessId 55555 | Should -Be $true
        }

        It "returns false for unregistered PIDs" {
            Test-IsSpawnedPid -ProcessId 66666 | Should -Be $false
        }
    }

    Context "Stop-ProcessTree (registry-guarded)" {
        It "refuses to kill unregistered PID" {
            $child = Start-Process -FilePath "powershell" -ArgumentList "Start-Sleep -Seconds 60" -PassThru
            Stop-ProcessTree -ProcessId $child.Id -Force
            $child.HasExited | Should -Be $false
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }

        It "kills registered PID" {
            $child = Start-Process -FilePath "powershell" -ArgumentList "Start-Sleep -Seconds 60" -PassThru
            Register-SpawnedPid -ProcessId $child.Id -AgentId "kill-test"
            Stop-ProcessTree -ProcessId $child.Id -Force
            $child.HasExited | Should -Be $true
        }
    }

    Context "Write-AtomicJson (stream durability)" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
        }

        BeforeEach {
            $testDir = Join-Path $TestDrive "atomic-test"
            $null = New-Item -ItemType Directory -Path $testDir -Force
        }

        It "writes JSON content atomically" {
            $targetPath = Join-Path $testDir "stream.json"
            Write-AtomicJson -Path $targetPath -InputObject @{ Id = 1; Namespace = "test-ns"; Role = "coder" }
            Test-Path $targetPath | Should -Be $true
            Test-Path "$targetPath.tmp" | Should -Be $false
            $content = Get-Content $targetPath -Raw | ConvertFrom-Json
            $content.Id | Should -Be 1
            $content.Namespace | Should -Be "test-ns"
        }

        It "writes pre-serialized JSON string" {
            $targetPath = Join-Path $testDir "stream.json"
            Write-AtomicJson -Path $targetPath -InputObject '{"Id":2,"Role":"reviewer"}'
            $content = Get-Content $targetPath -Raw | ConvertFrom-Json
            $content.Id | Should -Be 2
            $content.Role | Should -Be "reviewer"
        }

        It "overwrites existing file atomically" {
            $targetPath = Join-Path $testDir "stream.json"
            Set-Content $targetPath -Value '{"old":true}' -NoNewline
            Write-AtomicJson -Path $targetPath -InputObject @{ Id = 3 }
            $content = Get-Content $targetPath -Raw | ConvertFrom-Json
            $content.Id | Should -Be 3
        }
    }

    Context "Invoke-ReadFilesystemState dedup" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            . (Join-Path $script:OrchestratePrivate "State.ps1")
        }

        BeforeEach {
            $testDir = Join-Path $TestDrive "fs-state"
            $workingDir = Join-Path $testDir "Tasks/Working"
            $null = New-Item -ItemType Directory -Path $workingDir -Force

            $streamDir = Join-Path $workingDir "stream-1"
            $null = New-Item -ItemType Directory -Path $streamDir -Force
            Write-AtomicJson -Path (Join-Path $streamDir "stream.json") -InputObject @{ Id = 1; Namespace = "dup-ns"; Role = "coder" }
            $null = New-Item (Join-Path $streamDir "plan.md") -ItemType File -Force

            $existingStreams = @{
                "main|dup-ns|coder" = @{ Id = 1; Path = $streamDir; Namespace = "dup-ns"; Role = "coder" }
            }
            Mock Write-OrchestratorLog { }
        }

        It "skips streams already tracked in memory" {
            $result = Invoke-ReadFilesystemState -RepoDir $testDir -ExistingActiveStreams $existingStreams
            $result.activeStreams.Count | Should -Be 0
        }

        It "recovers streams not tracked in memory" {
            $result = Invoke-ReadFilesystemState -RepoDir $testDir
            $result.activeStreams.Count | Should -Be 1
            $result.activeStreams["main|dup-ns|coder"].Id | Should -Be 1
        }
    }

    Context "Invoke-ReconcileState repair" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            . (Join-Path $script:OrchestratePrivate "State.ps1")
        }

        BeforeEach {
            $testDir = Join-Path $TestDrive "reconcile"
            $workingDir = Join-Path $testDir "Tasks/Working"
            $null = New-Item -ItemType Directory -Path $workingDir -Force

            Mock Write-OrchestratorLog { }
        }

        It "re-creates stream.json for in-memory stream missing on disk" {
            $streamDir = Join-Path $workingDir "stream-1"
            $null = New-Item -ItemType Directory -Path $streamDir -Force
            $null = New-Item (Join-Path $streamDir "plan.md") -ItemType File -Force

            $activeStreams = @{
                "main|recover-ns|coder" = @{
                    Id = 1; Path = $streamDir; Namespace = "recover-ns"; Role = "coder"
                }
            }
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            Test-Path (Join-Path $streamDir "stream.json") | Should -Be $true
            $content = Get-Content (Join-Path $streamDir "stream.json") -Raw | ConvertFrom-Json
            $content.Id | Should -Be 1
            $content.Namespace | Should -Be "recover-ns"
        }

        It "adds disk-only stream to activeStreams" {
            $streamDir = Join-Path $workingDir "stream-2"
            $null = New-Item -ItemType Directory -Path $streamDir -Force
            Write-AtomicJson -Path (Join-Path $streamDir "stream.json") -InputObject @{ Id = 2; Namespace = "disk-only"; Role = "reviewer" }
            $null = New-Item (Join-Path $streamDir "plan.md") -ItemType File -Force

            $activeStreams = @{}
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            $activeStreams.ContainsKey("main|disk-only|reviewer") | Should -Be $true
            $activeStreams["main|disk-only|reviewer"].Id | Should -Be 2
            $activeStreams["main|disk-only|reviewer"].Status | Should -Be "recovered"
        }
    }

    Context "Clear-StaleAgentFiles summary" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "..\..\SalmonRun.AgentLifecycle\Public\Clear-StaleAgentFiles.ps1")
            . (Join-Path $script:OrchestratePrivate "..\..\SalmonRun.AgentLifecycle\Public\Test-AgentAlive.ps1")
            function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
            function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
            function Convert-PidSafe { param($Value); if ($Value -is [int]) { return $Value }; if ($Value -match '^\d+$') { return [int]$Value }; return $null }

            $script:aliveAgentDir = Join-Path $TestDrive "Tasks/Logs/agents"
            $null = New-Item -ItemType Directory -Path $script:aliveAgentDir -Force
            Mock Get-InterclawRepoRoot { return $TestDrive }
        }

        It "returns PSCustomObject with RemovedCount and RemovedFiles" {
            # Write a dead PID file
            "999999" | Out-File (Join-Path $script:aliveAgentDir "dead-agent.pid") -Encoding utf8 -NoNewline
            $result = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120
            $result.RemovedCount | Should -BeGreaterOrEqual 1
            $result.RemovedFiles[0] | Should -Match "agent="
            $result.RemovedFiles[0] | Should -Match "reason="
        }

        It "returns zero count when no stale agents exist" {
            $result = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120
            $result.RemovedCount | Should -Be 0
            $result.RemovedFiles.Count | Should -Be 0
        }

        It "includes mode and stdout files in cleanup" {
            "999999" | Out-File (Join-Path $script:aliveAgentDir "full-agent.pid") -Encoding utf8 -NoNewline
            "2000-01-01T00:00:00Z" | Out-File (Join-Path $script:aliveAgentDir "full-agent.heartbeat") -Encoding utf8 -NoNewline
            $null = New-Item (Join-Path $script:aliveAgentDir "full-agent.mode") -ItemType File -Force
            $null = New-Item (Join-Path $script:aliveAgentDir "full-agent.stdout") -ItemType File -Force
            # Verify files exist before cleanup
            (Test-Path (Join-Path $script:aliveAgentDir "full-agent.mode")) | Should -Be $true
            (Test-Path (Join-Path $script:aliveAgentDir "full-agent.stdout")) | Should -Be $true
            $result = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120
            # After cleanup, mode and stdout should be gone
            (Test-Path (Join-Path $script:aliveAgentDir "full-agent.mode")) | Should -Be $false
            (Test-Path (Join-Path $script:aliveAgentDir "full-agent.stdout")) | Should -Be $false
            $result.RemovedCount | Should -BeGreaterOrEqual 4
        }
    }

    Context "Get-CrashBackoffDelay (Capacity.ps1)" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Capacity.ps1")
        }

        It "returns 0 for empty crash history" {
            $history = [System.Collections.Generic.List[datetime]]::new()
            $delay = Get-CrashBackoffDelay -CrashHistory $history
            $delay | Should -Be 0
        }

        It "returns 0 for single crash" {
            $history = [System.Collections.Generic.List[datetime]]::new()
            $history.Add((Get-Date))
            $delay = Get-CrashBackoffDelay -CrashHistory $history
            $delay | Should -Be 0
        }

        It "returns exponential delay for multiple crashes" {
            $history = [System.Collections.Generic.List[datetime]]::new()
            $history.Add((Get-Date))
            $history.Add((Get-Date))
            $delay = Get-CrashBackoffDelay -CrashHistory $history
            $delay | Should -BeGreaterOrEqual 2
        }

        It "caps delay at MaxDelaySeconds" {
            $history = [System.Collections.Generic.List[datetime]]::new()
            for ($i = 0; $i -lt 10; $i++) { $history.Add((Get-Date)) }
            $delay = Get-CrashBackoffDelay -CrashHistory $history -MaxDelaySeconds 120
            $delay | Should -BeLessOrEqual 120
        }
    }

    Context "Resolve-Quarantine (RetryBudget.ps1)" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "RetryBudget.ps1")
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
        }

        It "restores quarantined files older than 1 hour" {
            $testDir = Join-Path $TestDrive "quarantine-restore"
            $failedDir = Join-Path $testDir "Tasks/Failed"
            $codeDir = Join-Path $testDir "Tasks/Code"
            $null = New-Item -ItemType Directory -Path $failedDir -Force
            $null = New-Item -ItemType Directory -Path $codeDir -Force
            $quarantinePath = Join-Path $failedDir "test-plan.md.quarantine"
            Set-Content $quarantinePath -Value "test" -NoNewline
            (Get-Item $quarantinePath).LastWriteTime = (Get-Date).AddHours(-2)
            # Stub Reset-FileRetry to avoid ModuleRoot dependency
            Mock Reset-FileRetry { }
            $result = Resolve-Quarantine -RepoDir $testDir
            $result | Should -Be 1
            Test-Path (Join-Path $codeDir "test-plan.md") | Should -Be $true
            Test-Path $quarantinePath | Should -Be $false
        }

        It "does not restore files newer than 1 hour" {
            $testDir = Join-Path $TestDrive "quarantine-skip"
            $failedDir = Join-Path $testDir "Tasks/Failed"
            $codeDir = Join-Path $testDir "Tasks/Code"
            $null = New-Item -ItemType Directory -Path $failedDir -Force
            $null = New-Item -ItemType Directory -Path $codeDir -Force
            Set-Content (Join-Path $failedDir "fresh-plan.md.quarantine") -Value "test" -NoNewline
            $result = Resolve-Quarantine -RepoDir $testDir
            $result | Should -Be 0
        }
    }

    Context "Orchestrator heartbeat refresh" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
        }

        It "refreshes heartbeat for agents with live processes" {
            $agentDir = Join-Path $TestDrive "Tasks/Logs/agents"
            $null = New-Item -ItemType Directory -Path $agentDir -Force
            $hbPath = Join-Path $agentDir "test-stream.heartbeat"
            Set-Content $hbPath -Value "2000-01-01T00:00:00Z" -NoNewline
            # Simulate active stream with a live process (current PowerShell)
            $streams = @{
                "test|coder" = @{
                    Id = "test-stream"
                    Process = (Get-Process -Id $PID)
                    Path = $TestDrive
                }
            }
            # Refresh heartbeat
            foreach ($__hbNs in @($streams.Keys)) {
                $__hbStream = $streams[$__hbNs]
                if ($__hbStream.Process -and -not $__hbStream.Process.HasExited) {
                    Set-Content $hbPath -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8 -NoNewline
                }
            }
            $hbContent = Get-Content $hbPath -Raw
            $hbDate = [datetime]::Parse($hbContent, [CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $age = ([datetime]::UtcNow - $hbDate.ToUniversalTime()).TotalSeconds
            $age | Should -BeLessOrEqual 5
        }

        It "does not refresh heartbeat for dead agents" {
            $agentDir = Join-Path $TestDrive "Tasks/Logs/agents"
            $null = New-Item -ItemType Directory -Path $agentDir -Force
            $hbPath = Join-Path $agentDir "dead-stream.heartbeat"
            Set-Content $hbPath -Value "2000-01-01T00:00:00Z" -NoNewline
            # Simulate dead stream (process with HasExited=true)
            $deadProc = Get-Process -Id $PID
            $deadProc | Add-Member -NotePropertyName "HasExited" -NotePropertyValue $true -Force
            $streams = @{
                "dead|coder" = @{
                    Id = "dead-stream"
                    Process = $deadProc
                    Path = $TestDrive
                }
            }
            foreach ($__hbNs in @($streams.Keys)) {
                $__hbStream = $streams[$__hbNs]
                if ($__hbStream.Process -and -not $__hbStream.Process.HasExited) {
                    Set-Content $hbPath -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8 -NoNewline
                }
            }
            $hbContent = Get-Content $hbPath -Raw
            $hbContent.Trim() | Should -Be "2000-01-01T00:00:00Z"
        }
    }

    Context "Stop-ProcessTree kills child processes" -Tag "Orchestrate", "Process", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Process.ps1")
            $testRegistry = Join-Path $TestDrive "tree-kill-pids.json"
            Initialize-SpawnedPidRegistry -RegistryPath $testRegistry
        }

        It "kills registered parent and its child processes" {
            # Spawn a parent PowerShell that spawns a child PowerShell
            $parentScript = "Start-Process -FilePath powershell -ArgumentList 'Start-Sleep -Seconds 60' -PassThru | Out-Null; Start-Sleep -Seconds 60"
            $parent = Start-Process -FilePath "powershell" -ArgumentList "-Command `"$parentScript`"" -PassThru
            Start-Sleep -Seconds 2
            # Find the child process
            $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($parent.Id)" -ErrorAction SilentlyContinue
            $childPid = if ($children) { [int]($children[0].ProcessId) } else { $null }
            # Register the parent so Stop-ProcessTree will kill it
            Register-SpawnedPid -ProcessId $parent.Id -AgentId "tree-kill-test"
            # Kill the tree
            Stop-ProcessTree -ProcessId $parent.Id -Force
            Start-Sleep -Seconds 1
            $parent.HasExited | Should -Be $true
            if ($childPid) {
                $childProc = Get-Process -Id $childPid -ErrorAction SilentlyContinue
                $childProc | Should -BeNullOrEmpty
            }
        }
    }

    Context "Invoke-ReadFilesystemState scans lane-* directories" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            . (Join-Path $script:OrchestratePrivate "State.ps1")
        }

        BeforeEach {
            $testDir = Join-Path $TestDrive "lane-state"
            $workingDir = Join-Path $testDir "Tasks/Working"
            $null = New-Item -ItemType Directory -Path $workingDir -Force

            # Create a lane-* directory (as used by persistent lanes)
            $laneDir = Join-Path $workingDir "lane-coder-1"
            $null = New-Item -ItemType Directory -Path $laneDir -Force
            Write-AtomicJson -Path (Join-Path $laneDir "stream.json") -InputObject @{
                Id = "lane-coder-1"; Namespace = "lane-ns"; Role = "coder"
            }
            $null = New-Item (Join-Path $laneDir "plan.md") -ItemType File -Force

            Mock Write-OrchestratorLog { }
        }

        It "recovers lane-* directories not tracked in memory" {
            $result = Invoke-ReadFilesystemState -RepoDir $testDir
            $result.activeStreams.Count | Should -Be 1
            $result.activeStreams.ContainsKey("main|lane-ns|coder") | Should -Be $true
            $result.activeStreams["main|lane-ns|coder"].Id | Should -Be "lane-coder-1"
        }

        It "skips lane-* directories already tracked in memory" {
            $existing = @{
                "main|lane-ns|coder" = @{ Id = "lane-coder-1"; Path = (Join-Path $testDir "Tasks/Working/lane-coder-1"); Namespace = "lane-ns"; Role = "coder" }
            }
            $result = Invoke-ReadFilesystemState -RepoDir $testDir -ExistingActiveStreams $existing
            $result.activeStreams.Count | Should -Be 0
        }
    }

    Context "Invoke-ReconcileState scans lane-* directories" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            . (Join-Path $script:OrchestratePrivate "State.ps1")
        }

        BeforeEach {
            $testDir = Join-Path $TestDrive "lane-reconcile"
            $workingDir = Join-Path $testDir "Tasks/Working"
            $null = New-Item -ItemType Directory -Path $workingDir -Force
            Mock Write-OrchestratorLog { }
        }

        It "re-creates stream.json for in-memory lane stream missing on disk" {
            $laneDir = Join-Path $workingDir "lane-coder-2"
            $null = New-Item -ItemType Directory -Path $laneDir -Force
            $null = New-Item (Join-Path $laneDir "plan.md") -ItemType File -Force

            $activeStreams = @{
                "main|lane-recover|coder" = @{
                    Id = "lane-coder-2"; Path = $laneDir; Namespace = "lane-recover"; Role = "coder"
                }
            }
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            Test-Path (Join-Path $laneDir "stream.json") | Should -Be $true
            $content = Get-Content (Join-Path $laneDir "stream.json") -Raw | ConvertFrom-Json
            $content.Id | Should -Be "lane-coder-2"
        }

        It "adds disk-only lane stream to activeStreams" {
            $laneDir = Join-Path $workingDir "lane-reviewer-1"
            $null = New-Item -ItemType Directory -Path $laneDir -Force
            Write-AtomicJson -Path (Join-Path $laneDir "stream.json") -InputObject @{
                Id = "lane-reviewer-1"; Namespace = "lane-disk"; Role = "reviewer"
            }
            $null = New-Item (Join-Path $laneDir "plan.md") -ItemType File -Force

            $activeStreams = @{}
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            $activeStreams.ContainsKey("main|lane-disk|reviewer") | Should -Be $true
            $activeStreams["main|lane-disk|reviewer"].Id | Should -Be "lane-reviewer-1"
        }
    }

    Context "Invoke-ReconcileState cleans up completed/empty streams (zombie fix)" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Stream.ps1")
            . (Join-Path $script:OrchestratePrivate "State.ps1")
        }

        BeforeEach {
            $testDir = Join-Path $TestDrive "zombie-reconcile"
            $workingDir = Join-Path $testDir "Tasks/Working"
            $null = New-Item -ItemType Directory -Path $workingDir -Force
            Mock Write-OrchestratorLog { }
        }

        It "does NOT add a completed stream (has .complete sentinel) to activeStreams" {
            $laneDir = Join-Path $workingDir "lane-coder-1"
            $null = New-Item -ItemType Directory -Path $laneDir -Force
            Write-AtomicJson -Path (Join-Path $laneDir "stream.json") -InputObject @{
                Id = "lane-coder-1"; Namespace = "zombie-ns"; Role = "coder"
            }
            # .complete sentinel present — stream is finished
            '{"exitCode":0}' | Set-Content (Join-Path $laneDir ".complete") -Encoding utf8 -NoNewline

            $activeStreams = @{}
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            $activeStreams.ContainsKey("main|zombie-ns|coder") | Should -Be $false
            Test-Path (Join-Path $laneDir "stream.json") | Should -Be $false
        }

        It "does NOT add an empty stream (no plan files) to activeStreams" {
            $laneDir = Join-Path $workingDir "lane-coder-2"
            $null = New-Item -ItemType Directory -Path $laneDir -Force
            Write-AtomicJson -Path (Join-Path $laneDir "stream.json") -InputObject @{
                Id = "lane-coder-2"; Namespace = "empty-ns"; Role = "coder"
            }
            # No plan files, no .complete — just a stale stream.json

            $activeStreams = @{}
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            $activeStreams.ContainsKey("main|empty-ns|coder") | Should -Be $false
            Test-Path (Join-Path $laneDir "stream.json") | Should -Be $false
        }

        It "DOES add a stream with plan files and no .complete to activeStreams" {
            $laneDir = Join-Path $workingDir "lane-coder-3"
            $null = New-Item -ItemType Directory -Path $laneDir -Force
            Write-AtomicJson -Path (Join-Path $laneDir "stream.json") -InputObject @{
                Id = "lane-coder-3"; Namespace = "active-ns"; Role = "coder"
            }
            $null = New-Item (Join-Path $laneDir "plan.md") -ItemType File -Force

            $activeStreams = @{}
            Invoke-ReconcileState -RepoDir $testDir -ActiveStreams $activeStreams -BusyNamespaces @{} -UsedNamespaces @{} | Out-Null
            $activeStreams.ContainsKey("main|active-ns|coder") | Should -Be $true
            $activeStreams["main|active-ns|coder"].Status | Should -Be "recovered"
        }
    }

    Context "Get-DynamicCapacity zombie recomputation" -Tag "Orchestrate", "Regression" {

        BeforeAll {
            . (Join-Path $script:OrchestratePrivate "Capacity.ps1")
        }

        It "returns non-zero capacity when zombie streams are detected (forcing a slot)" {
            # Simulate: 3 total slots, 3 active (all zombies with no Process),
            # both coder and reviewer have work
            $script:activeStreams = @{
                "zombie-ns|coder" = @{ Process = $null }
                "zombie-ns2|coder" = @{ Process = $null }
                "zombie-ns3|reviewer" = @{ Process = $null }
            }
            Mock Write-OrchestratorLog { }

            $result = Get-DynamicCapacity -CodeParallelCount 3 -ReviewerParallelCount 3 -CoderWorkload 5 -ReviewerWorkload 5 -ActiveCoder 2 -ActiveReviewer 1
            # Without the fix, both capacities would be 0.
            # With the fix, at least one should be > 0.
            ($result.CapacityCoder + $result.CapacityReviewer) | Should -BeGreaterThan 0
        }

        It "returns zero capacity when no zombies and all slots full" {
            $script:activeStreams = @{
                "live-ns|coder" = @{ Process = @{ HasExited = $false } }
                "live-ns2|coder" = @{ Process = @{ HasExited = $false } }
                "live-ns3|reviewer" = @{ Process = @{ HasExited = $false } }
            }
            Mock Write-OrchestratorLog { }

            $result = Get-DynamicCapacity -CodeParallelCount 3 -ReviewerParallelCount 3 -CoderWorkload 5 -ReviewerWorkload 5 -ActiveCoder 2 -ActiveReviewer 1
            $result.CapacityCoder | Should -Be 0
            $result.CapacityReviewer | Should -Be 0
        }
    }
}
