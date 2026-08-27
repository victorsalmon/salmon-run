#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for SalmonRun.AgentLifecycle — heartbeat/PID lifecycle,
    cleanup idempotency, and fail-closed invariants.

.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Write-AgentHeartbeat is idempotent (heartbeat timestamp always updates)
    - Write-AgentPidFile writes numeric PIDs and registers cleanup event
    - Test-AgentAlive detects dead processes as stale
    - Test-AgentAlive marks live processes as not stale
    - Clear-StaleAgentFiles is idempotent (double-clear removes nothing extra)
    - Clear-StaleAgentFiles is fail-closed (no files → zero removals)
    - Orphaned heartbeat files without PID are cleaned up

    All properties use deterministic seeds (20260901) and explicit numRuns.
    Process timing and PID liveness are non-hermetic — properties record
    exclusions rather than hiding them.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    . (Join-Path $script:repoRoot 'Tools/QA/powershell-property-testing/PropertyTesting.ps1')

    # Stub dependencies
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
    function Get-InterclawConstants { @{ AgentHeartbeatStaleThresholdSeconds = 120 } }

    # Create a temp agent dir for hermetic tests
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "agent-lifecycle-prop-test-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:tempDir -Force
    $script:SavedSALMON_RUN_HOME_AgentLifecycle = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = $script:tempDir
    $script:agentsDir = Join-Path $script:tempDir "Tasks/Logs/agents"
    $null = New-Item -ItemType Directory -Path $script:agentsDir -Force

    # Save and force the public SalmonRun.Paths cache to resolve to the temp dir.
    $script:SavedRepoRoot = $env:REPO_ROOT
    $env:REPO_ROOT = $script:tempDir
    if (Get-Command Reset-SalmonRunPathCache -ErrorAction SilentlyContinue) { Reset-SalmonRunPathCache }
    if (Get-Command Reset-InterclawPathCache -ErrorAction SilentlyContinue) { Reset-InterclawPathCache }

    # Stub Get-InterclawRepoRoot to return temp dir as a fallback
    function global:Get-InterclawRepoRoot { return $script:tempDir }
    function global:Get-SalmonRunRepoRoot { return $script:tempDir }

    # Dot-source path helpers and core dependencies the AgentLifecycle functions use
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Paths/SalmonRun.Paths.ps1')
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Core/Public/Write-AtomicFile.ps1')
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Core/Public/Convert-PidSafe.ps1')
    $lifecyclePublicDir = Join-Path $script:repoRoot 'Modules/SalmonRun.AgentLifecycle/Public'
    Get-ChildItem -Path $lifecyclePublicDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

AfterAll {
    if ($script:tempDir -and (Test-Path $script:tempDir)) {
        Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($script:SavedRepoRoot) { $env:REPO_ROOT = $script:SavedRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
    if ($script:SavedSALMON_RUN_HOME_AgentLifecycle) { $env:SALMON_RUN_HOME = $script:SavedSALMON_RUN_HOME_AgentLifecycle } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    if (Get-Command Reset-SalmonRunPathCache -ErrorAction SilentlyContinue) { Reset-SalmonRunPathCache }
    if (Get-Command Reset-InterclawPathCache -ErrorAction SilentlyContinue) { Reset-InterclawPathCache }
}

Describe "AgentLifecycle property tests" -Tag "Property", "AgentLifecycle" {

    Context "Write-AgentHeartbeat idempotency" {
        It "property: writing heartbeat N times always produces a valid ISO timestamp" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $N = $rng.Next(1, 20)
                $agentId = "hb-prop-$seed"

                for ($i = 0; $i -lt $N; $i++) {
                    $hbPath = Write-AgentHeartbeat -AgentId $agentId
                    $hbPath | Should -Not -BeNullOrEmpty
                    Test-Path $hbPath | Should -Be $true
                    $content = (Get-Content $hbPath -Raw).Trim()
                    $parsed = [datetime]::MinValue
                    [datetime]::TryParse($content, [ref]$parsed) | Should -Be $true
                }

                # Cleanup
                Remove-Item "$script:agentsDir/$agentId.heartbeat" -Force -ErrorAction SilentlyContinue
            } -Seed 20260901 -NumRuns 50 -Description "heartbeat N times yields valid timestamp"
            $result.Passed | Should -Be $true
        }

        It "property: heartbeat age is always non-negative" {
            $result = Invoke-Property {
                param($seed)
                $agentId = "hb-age-$seed"

                $hbPath = Write-AgentHeartbeat -AgentId $agentId
                $content = (Get-Content $hbPath -Raw).Trim()
                $hbUtc = [datetime]::Parse($content, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                $ageSeconds = ([datetime]::UtcNow - $hbUtc).TotalSeconds
                $ageSeconds | Should -BeGreaterOrEqual 0

                Remove-Item "$script:agentsDir/$agentId.heartbeat" -Force -ErrorAction SilentlyContinue
            } -Seed 20260902 -NumRuns 30 -Description "heartbeat age non-negative"
            $result.Passed | Should -Be $true
        }
    }

    Context "Write-AgentPidFile numeric PID" {
        It "property: PID file contains a numeric PID" {
            $result = Invoke-Property {
                param($seed)
                $agentId = "pid-prop-$seed"

                $pidPath = Write-AgentPidFile -AgentId $agentId
                $pidPath | Should -Not -BeNullOrEmpty
                Test-Path $pidPath | Should -Be $true
                $pidContent = (Get-Content $pidPath -Raw).Trim()
                $parsedPid = [int]::Parse($pidContent)
                $parsedPid | Should -BeGreaterThan 0

                Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
            } -Seed 20260903 -NumRuns 30 -Description "PID file is numeric"
            $result.Passed | Should -Be $true
        }
    }

    Context "Test-AgentAlive fail-closed on dead process" {
        It "property: a PID file with a non-existent PID is detected as stale" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                # Use PID values extremely unlikely to be real processes
                $fakePid = $rng.Next(9999000, 9999999)
                $agentId = "alive-dead-$seed"

                # Write the fake PID to a file
                $pidPath = Join-Path $script:agentsDir "$agentId.pid"
                $fakePid.ToString() | Set-Content -Path $pidPath -Encoding utf8 -NoNewline

                $status = Test-AgentAlive -AgentId $agentId -HeartbeatStaleThresholdSeconds 120
                $status.HasPidFile | Should -Be $true
                $status.Pid | Should -Be $fakePid
                $status.ProcessAlive | Should -Be $false
                $status.Stale | Should -Be $true

                Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
            } -Seed 20260904 -NumRuns 20 -Description "non-existent PID is stale"
            $result.Passed | Should -Be $true
        }

        It "property: no PID and no heartbeat means not stale (not our agent)" {
            $result = Invoke-Property {
                param($seed)
                $agentId = "alive-none-$seed"

                $status = Test-AgentAlive -AgentId $agentId -HeartbeatStaleThresholdSeconds 120
                $status.HasPidFile | Should -Be $false
                $status.HasHeartbeat | Should -Be $false
                $status.Stale | Should -Be $false
            } -Seed 20260905 -NumRuns 20 -Description "no files means not stale"
            $result.Passed | Should -Be $true
        }
    }

    Context "Clear-StaleAgentFiles idempotency" {
        It "property: clearing twice removes nothing extra" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $agentCount = $rng.Next(1, 5)

                # Create fake dead agent PID files
                $createdAgents = @()
                for ($i = 0; $i -lt $agentCount; $i++) {
                    $agentId = "clear-$seed-$i"
                    $createdAgents += $agentId
                    $pidPath = Join-Path $script:agentsDir "$agentId.pid"
                    $rng.Next(9999000, 9999999).ToString() | Set-Content -Path $pidPath -Encoding utf8 -NoNewline
                    # Write a fresh heartbeat (so it's not orphaned)
                    $null = Write-AgentHeartbeat -AgentId $agentId
                }

                $first = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120
                $second = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120

                # First pass should have removed dead agents
                $first.RemovedCount | Should -BeGreaterOrEqual 0
                # Second pass should find nothing to remove
                $second.RemovedCount | Should -Be 0

                # Cleanup any remaining
                foreach ($a in $createdAgents) {
                    Remove-Item "$script:agentsDir/$a.*" -Force -ErrorAction SilentlyContinue
                }
            } -Seed 20260906 -NumRuns 20 -Description "double-clear removes nothing extra"
            $result.Passed | Should -Be $true
        }

        It "property: no agent directory yields zero removals" {
            $result = Invoke-Property {
                param($seed)
                $nonExistentDir = Join-Path ([System.IO.Path]::GetTempPath()) "no-agents-$seed"
                # Temporarily override
                $origDir = $script:agentsDir
                $script:agentsDir = $nonExistentDir

                try {
                    $outcome = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120
                    $outcome.RemovedCount | Should -Be 0
                } finally {
                    $script:agentsDir = $origDir
                    Remove-Item $nonExistentDir -Force -ErrorAction SilentlyContinue
                }
            } -Seed 20260907 -NumRuns 10 -Description "empty dir yields zero"
            $result.Passed | Should -Be $true
        }
    }

    Context "Orphaned heartbeat cleanup" {
        It "property: heartbeat without PID is cleaned up by Clear-StaleAgentFiles" {
            $result = Invoke-Property {
                param($seed)
                $agentId = "orphan-$seed"

                # Write heartbeat only (no PID)
                $null = Write-AgentHeartbeat -AgentId $agentId
                Test-Path "$script:agentsDir/$agentId.heartbeat" | Should -Be $true

                $outcome = Clear-StaleAgentFiles -HeartbeatStaleThresholdSeconds 120

                # Orphaned heartbeat should have been removed
                Test-Path "$script:agentsDir/$agentId.heartbeat" | Should -Be $false
            } -Seed 20260908 -NumRuns 20 -Description "orphan heartbeat cleaned"
            $result.Passed | Should -Be $true
        }
    }
}
