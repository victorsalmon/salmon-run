#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.AgentLifecycle Module" -Tag "Core" {
    BeforeAll {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $dockerModules = Join-Path $repoRoot 'Modules'

        $diagnosticsPath = Join-Path $dockerModules 'SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }

        $pathsPath = Join-Path $dockerModules 'SalmonRun.Paths\SalmonRun.Paths.ps1'
        if (Test-Path $pathsPath) { . $pathsPath }

        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        if (Test-Path $corePublic) {
            . (Join-Path $corePublic 'Write-AtomicFile.ps1')
            . (Join-Path $corePublic 'Convert-PidSafe.ps1')
        }

        $agentLifecyclePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.AgentLifecycle\Public'
        if (Test-Path $agentLifecyclePublic) {
            foreach ($f in (Get-ChildItem -Path $agentLifecyclePublic -Filter '*.ps1')) { . $f.FullName }
        }

        $script:TestAgentId = "pester-al-test-agent-888-88"
        $script:AgentTestDir = Join-Path $env:TEMP "Interclaw-AgentLifecycle-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:AgentTestDir -Force
        $script:SavedSALMON_RUN_HOME_AL = $env:SALMON_RUN_HOME
        $env:SALMON_RUN_HOME = $script:AgentTestDir
        $script:AgentsDir = Join-Path (Get-SalmonTaskRoot) "Logs\agents"

        function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
    }
    AfterEach {
        Remove-Item "$script:AgentsDir\$script:TestAgentId*" -Force -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item "$script:AgentsDir\$script:TestAgentId*" -Force -ErrorAction SilentlyContinue
        if (Test-Path $script:AgentTestDir) { Remove-Item $script:AgentTestDir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($script:SavedSALMON_RUN_HOME_AL) { $env:SALMON_RUN_HOME = $script:SavedSALMON_RUN_HOME_AL } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    }

    Context "Write-AgentPidFile" -Tag "AgentLifecycle" {
        It "creates a PID file with the current shell PID" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            $pidPath = "$script:AgentsDir/$script:TestAgentId.pid"
            Test-Path $pidPath | Should -Be $true
            (Get-Content $pidPath -Raw).Trim() | Should -Be $PID.ToString()
        }

        It "creates the agent directory if absent" {
            Remove-Item $script:AgentsDir -Force -Recurse -ErrorAction SilentlyContinue
            Write-AgentPidFile -AgentId $script:TestAgentId
            $pidPath = "$script:AgentsDir/$script:TestAgentId.pid"
            Test-Path $pidPath | Should -Be $true
        }

        It "registers an EngineEvent for cleanup" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            $subscriber = Get-EventSubscriber -SourceIdentifier "SalmonRun.PidCleanup_$script:TestAgentId" -Force -ErrorAction SilentlyContinue
            $subscriber | Should -Not -BeNullOrEmpty
        }

        It "returns the path to the PID file" {
            $result = Write-AgentPidFile -AgentId $script:TestAgentId
            $result | Should -Match "$script:TestAgentId\.pid$"
        }
    }

    Context "Write-AgentHeartbeat" -Tag "AgentLifecycle" {
        It "creates a heartbeat file with a valid timestamp" {
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $hbPath = "$script:AgentsDir/$script:TestAgentId.heartbeat"
            Test-Path $hbPath | Should -Be $true
            $content = (Get-Content $hbPath -Raw).Trim()
            { [datetime]::Parse($content) } | Should -Not -Throw
        }

        It "updates the heartbeat file on subsequent calls" {
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $ts1 = (Get-Content "$script:AgentsDir/$script:TestAgentId.heartbeat" -Raw).Trim()
            Start-Sleep -Milliseconds 10
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $ts2 = (Get-Content "$script:AgentsDir/$script:TestAgentId.heartbeat" -Raw).Trim()
            $ts2 | Should -Not -Be $ts1
        }

        It "does not throw when agents dir is missing" {
            Remove-Item $script:AgentsDir -Force -Recurse -ErrorAction SilentlyContinue
            { Write-AgentHeartbeat -AgentId $script:TestAgentId } | Should -Not -Throw
        }
    }

    Context "Test-AgentAlive" -Tag "AgentLifecycle" {
        It "returns correct properties when agent is alive with PID and heartbeat" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $result = Test-AgentAlive -AgentId $script:TestAgentId
            $result.AgentId | Should -Be $script:TestAgentId
            $result.HasPidFile | Should -Be $true
            $result.HasHeartbeat | Should -Be $true
            $result.ProcessAlive | Should -Be $true
            $result.Pid | Should -Be $PID
            $result.Stale | Should -Be $false
        }

        It "detects stale when PID file points to a dead process" {
            "999999" | Out-File "$script:AgentsDir/$script:TestAgentId.pid" -Encoding utf8 -NoNewline
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $result = Test-AgentAlive -AgentId $script:TestAgentId
            $result.ProcessAlive | Should -Be $false
            $result.Stale | Should -Be $true
        }

        It "returns not stale when no files exist" {
            $result = Test-AgentAlive -AgentId "nonexistent-al-agent-000-00"
            $result.HasPidFile | Should -Be $false
            $result.HasHeartbeat | Should -Be $false
            $result.Stale | Should -Be $false
        }
    }

    Context "Clear-StaleAgentFiles" -Tag "AgentLifecycle" {
        It "removes PID and heartbeat files for dead agents" {
            "999999" | Out-File "$script:AgentsDir/${testAgentId}dead.pid" -Encoding utf8 -NoNewline
            "2000-01-01T00:00:00Z" | Out-File "$script:AgentsDir/${testAgentId}dead.heartbeat" -Encoding utf8 -NoNewline
            Clear-StaleAgentFiles
            Test-Path "$script:AgentsDir/${testAgentId}dead.pid" | Should -Be $false
            Test-Path "$script:AgentsDir/${testAgentId}dead.heartbeat" | Should -Be $false
        }

        It "does not remove files for alive agents" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            Clear-StaleAgentFiles
            Test-Path "$script:AgentsDir/$script:TestAgentId.pid" | Should -Be $true
            Test-Path "$script:AgentsDir/$script:TestAgentId.heartbeat" | Should -Be $true
        }

        It "returns summary with removed files details" {
            "999999" | Out-File "$script:AgentsDir/${testAgentId}a.pid" -Encoding utf8 -NoNewline
            "999999" | Out-File "$script:AgentsDir/${testAgentId}b.pid" -Encoding utf8 -NoNewline
            "2000-01-01T00:00:00Z" | Out-File "$script:AgentsDir/${testAgentId}a.heartbeat" -Encoding utf8 -NoNewline
            $result = Clear-StaleAgentFiles
            $result.RemovedCount | Should -BeGreaterOrEqual 2
            $result.RemovedFiles.Count | Should -BeGreaterOrEqual 2
            $result.RemovedFiles[0] | Should -Match "agent="
        }
    }
}
