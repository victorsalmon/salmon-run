#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $__modulesDir = [System.IO.Path]::Combine($__repoRoot, "Skills", "Docker", "Modules")

    $__orchestrateDir = [System.IO.Path]::Combine($__repoRoot, "Skills", "Orchestrator", "Salmon", "Modules", "SalmonRun.Orchestrate")
    . (Join-Path $__orchestrateDir "Private\Stream.ps1")
    $__agentLifecycleDir = [System.IO.Path]::Combine($__repoRoot, "Skills", "Orchestrator", "Salmon", "Modules", "SalmonRun.AgentLifecycle")
    . (Join-Path $__agentLifecycleDir "Public\Test-AgentAlive.ps1")

    function Convert-PidSafe {
        param($Value)
        if ($Value -is [int]) { return $Value }
        if ($Value -match '^\d+$') { return [int]$Value }
        return $null
    }
    $script:orchLogMessages = [System.Collections.Generic.List[string]]::new()
    function Write-OrchestratorLog {
        param($Message, [string]$Level = "INFO")
        $script:orchLogMessages.Add("[$Level] $Message")
    }

    function Get-InterclawRepoRoot { return $TestDrive }
    function Get-SkillsRoot { param([string]$RepoRoot) return Join-Path $RepoRoot "Skills" }
}

Describe "Invoke-LaneStateRecovery live-agent guard" -Tag "Orchestrate", "Regression" {

    It "does not move files when the lane's agent process is alive but absent from ActiveStreams" {
        $script:orchLogMessages.Clear()
        $workingDir = Join-Path $TestDrive "Tasks/Working"
        $laneDir = Join-Path $workingDir "lane-test-1"
        $null = New-Item -ItemType Directory -Path $laneDir -Force
        @{ Id = "lane-test-1"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json | Set-Content (Join-Path $laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $laneDir "plan.md"
        Set-Content $planPath -Value "**Lock**`n- Agent: lane-test-1`n- Status: locked`n---`n# plan" -Encoding utf8

        # PID file pointing at the current process — guaranteed alive
        $agentsDir = Join-Path $TestDrive "Tasks/Logs/agents"
        $null = New-Item -ItemType Directory -Path $agentsDir -Force
        Set-Content (Join-Path $agentsDir "lane-test-1.pid") -Value $PID -Encoding utf8 -NoNewline

        $lanes = @(@{ Id = "lane-test-1"; Path = $laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 0
        Test-Path $planPath | Should -Be $true
        Test-Path (Join-Path $TestDrive "Tasks/Code/plan.md") | Should -Be $false
        ($script:orchLogMessages -join "`n") | Should -Match "LANE_HOLD lane='lane-test-1' reason='agent_pid_alive'"
    }

    It "moves files and logs FILE_MOVED when the lane's agent process is dead" {
        $script:orchLogMessages.Clear()
        $workingDir = Join-Path $TestDrive "Tasks/Working"
        $laneDir = Join-Path $workingDir "lane-test-2"
        $null = New-Item -ItemType Directory -Path $laneDir -Force
        @{ Id = "lane-test-2"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json | Set-Content (Join-Path $laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $laneDir "plan.md"
        Set-Content $planPath -Value "# plan" -Encoding utf8

        # PID file pointing at a dead process
        $agentsDir = Join-Path $TestDrive "Tasks/Logs/agents"
        $null = New-Item -ItemType Directory -Path $agentsDir -Force
        Set-Content (Join-Path $agentsDir "lane-test-2.pid") -Value "999999" -Encoding utf8 -NoNewline
        # Destination dirs must exist for the recovery move
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Tasks/Code") -Force

        $lanes = @(@{ Id = "lane-test-2"; Path = $laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path $planPath | Should -Be $false
        Test-Path (Join-Path $TestDrive "Tasks/Code/plan.md") | Should -Be $true
        ($script:orchLogMessages -join "`n") | Should -Match "FILE_MOVED file='plan.md' from=lane-test-2/ to=Code/ reason=lane_recovery"
    }
}

Describe "Invoke-LaneStateRecovery terminal-state guard" -Tag "Orchestrate", "Regression" {

    BeforeEach {
        $script:orchLogMessages.Clear()
        $script:laneDir = Join-Path $TestDrive "Tasks/Working/lane-recovery-test"
        $null = New-Item -ItemType Directory -Path $script:laneDir -Force
        # Dead-agent PID so the live-agent guard does not hold the lane
        $agentsDir = Join-Path $TestDrive "Tasks/Logs/agents"
        $null = New-Item -ItemType Directory -Path $agentsDir -Force
        Set-Content (Join-Path $agentsDir "lane-recovery-test.pid") -Value "999999" -Encoding utf8 -NoNewline
        # Destination / terminal dirs must exist for the recovery sweep
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Tasks/Code") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Tasks/Review") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Tasks/Complete") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Tasks/Failed") -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive "Tasks/Archive") -Force
    }

    It "does not re-dispatch a plan already present in Tasks/Complete/" {
        $planName = "2026-08-04-csbk-bank-0-immutable-statements.md"
        @{ Id = "lane-recovery-test"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json |
            Set-Content (Join-Path $script:laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $script:laneDir $planName
        Set-Content $planPath -Value "# plan`n**Status**: ready" -Encoding utf8
        # The plan was already completed and archived
        Set-Content (Join-Path $TestDrive "Tasks/Complete/$planName") -Value "# completed plan" -Encoding utf8

        $lanes = @(@{ Id = "lane-recovery-test"; Path = $script:laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path (Join-Path $TestDrive "Tasks/Code/$planName") | Should -Be $false
        Test-Path $planPath | Should -Be $false
        ($script:orchLogMessages -join "`n") | Should -Match "LANE_RECOVERY_SKIP_TERMINAL file='$planName'"
    }

    It "does not re-dispatch a plan already present in Tasks/Failed/" {
        $planName = "2026-08-16-lane-recovery-liveness-4c.md"
        @{ Id = "lane-recovery-test"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json |
            Set-Content (Join-Path $script:laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $script:laneDir $planName
        Set-Content $planPath -Value "# plan`n**Status**: ready" -Encoding utf8
        Set-Content (Join-Path $TestDrive "Tasks/Failed/$planName") -Value "# failed plan" -Encoding utf8

        $lanes = @(@{ Id = "lane-recovery-test"; Path = $script:laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path (Join-Path $TestDrive "Tasks/Code/$planName") | Should -Be $false
        Test-Path $planPath | Should -Be $false
        ($script:orchLogMessages -join "`n") | Should -Match "LANE_RECOVERY_SKIP_TERMINAL file='$planName'"
    }

    It "does not re-dispatch a plan already present in Tasks/Archive/" {
        $planName = "2026-08-04-csbk-etv-0-every-transaction-view.md"
        @{ Id = "lane-recovery-test"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json |
            Set-Content (Join-Path $script:laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $script:laneDir $planName
        Set-Content $planPath -Value "# plan`n**Status**: ready" -Encoding utf8
        Set-Content (Join-Path $TestDrive "Tasks/Archive/$planName") -Value "# archived plan" -Encoding utf8

        $lanes = @(@{ Id = "lane-recovery-test"; Path = $script:laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path (Join-Path $TestDrive "Tasks/Code/$planName") | Should -Be $false
        Test-Path $planPath | Should -Be $false
        ($script:orchLogMessages -join "`n") | Should -Match "LANE_RECOVERY_SKIP_TERMINAL file='$planName'"
    }

    It "does not re-dispatch a coder plan whose Status field is a terminal/non-ready value" {
        $planName = "2026-08-04-functional-currentsbk-0-package-scripts-ci.md"
        @{ Id = "lane-recovery-test"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json |
            Set-Content (Join-Path $script:laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $script:laneDir $planName
        Set-Content $planPath -Value "# plan`n**Status**: voided" -Encoding utf8

        $lanes = @(@{ Id = "lane-recovery-test"; Path = $script:laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path (Join-Path $TestDrive "Tasks/Code/$planName") | Should -Be $false
        Test-Path $planPath | Should -Be $false
        ($script:orchLogMessages -join "`n") | Should -Match "LANE_RECOVERY_SKIP_STATUS file='$planName'"
    }

    It "routes a released coder plan to Review/ (existing behavior preserved)" {
        $planName = "2026-08-04-csbk-recon-0-auto-reconciliation.md"
        @{ Id = "lane-recovery-test"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json |
            Set-Content (Join-Path $script:laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $script:laneDir $planName
        Set-Content $planPath -Value "# plan`n**Status**: released" -Encoding utf8

        $lanes = @(@{ Id = "lane-recovery-test"; Path = $script:laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path (Join-Path $TestDrive "Tasks/Code/$planName") | Should -Be $false
        Test-Path (Join-Path $TestDrive "Tasks/Review/$planName") | Should -Be $true
    }

    It "still moves a ready coder plan with no terminal-queue presence (existing behavior preserved)" {
        $planName = "2026-08-21-fresh-plan-0-example.md"
        @{ Id = "lane-recovery-test"; Namespace = "test-ns"; Role = "coder" } | ConvertTo-Json |
            Set-Content (Join-Path $script:laneDir "stream.json") -Encoding utf8
        $planPath = Join-Path $script:laneDir $planName
        Set-Content $planPath -Value "# plan`n**Status**: ready" -Encoding utf8

        $lanes = @(@{ Id = "lane-recovery-test"; Path = $script:laneDir; Role = "coder"; Idle = $false })
        $recovered = Invoke-LaneStateRecovery -InterclawDir $TestDrive -Lanes $lanes -ActiveStreams @{}

        $recovered | Should -Be 1
        Test-Path $planPath | Should -Be $false
        Test-Path (Join-Path $TestDrive "Tasks/Code/$planName") | Should -Be $true
    }
}

Describe "Test-AgentAlive process-alive ground truth" -Tag "AgentLifecycle", "Regression" {

    BeforeEach {
        $script:aliveAgentsDir = Join-Path $TestDrive "Tasks/Logs/agents"
        $null = New-Item -ItemType Directory -Path $script:aliveAgentsDir -Force
    }

    It "returns Stale=false when process is alive despite a stale heartbeat" {
        $agentId = "lane-test-alive"
        Set-Content (Join-Path $script:aliveAgentsDir "$agentId.pid") -Value $PID -Encoding utf8 -NoNewline
        Set-Content (Join-Path $script:aliveAgentsDir "$agentId.heartbeat") -Value "2000-01-01T00:00:00Z" -Encoding utf8 -NoNewline

        $result = Test-AgentAlive -AgentId $agentId -HeartbeatStaleThresholdSeconds 60
        $result.ProcessAlive | Should -Be $true
        $result.HeartbeatStale | Should -Be $true
        $result.Stale | Should -Be $false
    }

    It "returns Stale=true when PID file points to a dead process" {
        $agentId = "lane-test-dead"
        Set-Content (Join-Path $script:aliveAgentsDir "$agentId.pid") -Value "999999" -Encoding utf8 -NoNewline
        Set-Content (Join-Path $script:aliveAgentsDir "$agentId.heartbeat") -Value "2000-01-01T00:00:00Z" -Encoding utf8 -NoNewline

        $result = Test-AgentAlive -AgentId $agentId -HeartbeatStaleThresholdSeconds 60
        $result.ProcessAlive | Should -Be $false
        $result.Stale | Should -Be $true
    }
}

Describe "Reset-PlanLockHeader encoding preservation" -Tag "Orchestrator", "Encoding", "Regression" {

    BeforeEach {
        $script:encodeDir = Join-Path $TestDrive "encode-test"
        $null = New-Item -ItemType Directory -Path $script:encodeDir -Force
    }

    It "preserves CRLF line endings and UTF-8 em-dashes through lock-header strip" {
        $planPath = Join-Path $script:encodeDir "plan-crlf.md"
        $emDash = [string][char]0x2014
        $body = "**Lock**`r`n- Agent: lane-test-1`r`n- Status: locked`r`n---`r`n# Session Plan: encoding-test`r`n`r`n**Status**: ready $emDash em-dash`r`n"
        [System.IO.File]::WriteAllText($planPath, $body, [System.Text.Encoding]::UTF8)

        Reset-PlanLockHeader -FilePath $planPath

        $result = [System.IO.File]::ReadAllText($planPath, [System.Text.Encoding]::UTF8)
        $result | Should -Match "`r`n" -Because "CRLF must be preserved, not stripped to single-line"
        $result | Should -Match $emDash -Because "UTF-8 em-dash must not be mojibake'd"
        $result | Should -Not -Match "^\*\*Lock\*\*" -Because "the Lock block should be stripped"
        $result | Should -Match "# Session Plan: encoding-test" -Because "the plan body must survive"
        ($result -split "`n").Count | Should -BeGreaterThan 3 -Because "the file must not be single-lined"
    }

    It "preserves CRLF and em-dashes when the file has no lock header (no-op path)" {
        $planPath = Join-Path $script:encodeDir "plan-nolock.md"
        $emDash = [string][char]0x2014
        $body = "# Session Plan: no-lock-test`r`n`r`n**Status**: ready $emDash em-dash`r`n"
        [System.IO.File]::WriteAllText($planPath, $body, [System.Text.Encoding]::UTF8)

        Reset-PlanLockHeader -FilePath $planPath

        $result = [System.IO.File]::ReadAllText($planPath, [System.Text.Encoding]::UTF8)
        $result | Should -Match "`r`n" -Because "CRLF must be preserved even on the no-op path"
        $result | Should -Match $emDash -Because "em-dash must survive the no-op path"
    }
}

Describe "Resolve-OrphanStatus encoding preservation" -Tag "Orchestrator", "Encoding", "Regression" {

    BeforeAll {
        $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
        $__orphanPath = Join-Path $__repoRoot "Skills" "Orchestrator" "Salmon" "Modules" "SalmonRun.Orchestrate" "Private" "Orphan.ps1"
        if (-not (Get-Command Resolve-OrphanStatus -ErrorAction SilentlyContinue)) {
            . $__orphanPath
        }
        # Stub dependencies that Resolve-OrphanStatus calls
        if (-not (Get-Command Test-AgentAlive -ErrorAction SilentlyContinue)) {
            function Test-AgentAlive { param($AgentId) return $null }
        }
        if (-not (Get-Command Write-OrchestratorLog -ErrorAction SilentlyContinue)) {
            function Write-OrchestratorLog { param($Message, [string]$Level = "INFO") }
        }
        if (-not (Get-Command Convert-PidSafe -ErrorAction SilentlyContinue)) {
            function Convert-PidSafe { param($Value) return $null }
        }
    }

    BeforeEach {
        $script:orphanDir = Join-Path $TestDrive "orphan-test"
        $script:workingDir = Join-Path $script:orphanDir "Tasks" "Working" "lane-test-1"
        $script:reviewDir = Join-Path $script:orphanDir "Tasks" "Review"
        $null = New-Item -ItemType Directory -Path $script:workingDir -Force
        $null = New-Item -ItemType Directory -Path $script:reviewDir -Force
    }

    It "stamps a canonical release header with RescueReason without corrupting CRLF or em-dashes" {
        $emDash = [string][char]0x2014
        $planName = "encoding-orphan-test.md"
        $planPath = Join-Path $script:workingDir $planName
        $body = "**Lock**`r`n- Agent: lane-test-1`r`n- Status: locked`r`n---`r`n# Session Plan: orphan-encoding $emDash em-dash`r`n"
        [System.IO.File]::WriteAllText($planPath, $body, [System.Text.Encoding]::UTF8)

        $file = Get-Item $planPath
        Resolve-OrphanStatus -File $file -Agent "lane-test-1" -InterclawDir $script:orphanDir -RescueKind "RESCUE_TEST"

        $destPath = Join-Path $script:reviewDir $planName
        Test-Path $destPath | Should -Be $true -Because "the file should be moved to Review/"
        $result = [System.IO.File]::ReadAllText($destPath, [System.Text.Encoding]::UTF8)
        $result | Should -Match "`r`n" -Because "CRLF must be preserved through the release stamp"
        $result | Should -Match $emDash -Because "em-dash must not be mojibake'd"
        $result | Should -Match "Status: released" -Because "the lock status should be updated to released"
        $result | Should -Match "- Released:" -Because "a Released timestamp should be stamped"
        $result | Should -Match "RescueReason: RESCUE_TEST" -Because "the RescueReason should be stamped for audit trail"
        ($result -split "`n").Count | Should -BeGreaterThan 3 -Because "the file must not be single-lined"
    }
}
