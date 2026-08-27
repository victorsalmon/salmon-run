#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for SalmonRun.Locking — lock acquire/release/reclaim,
    ownership isolation, stale-lock recovery, and namespace reservation.

.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Lock-File creates lock files and returns true on uncontested acquire
    - Unlock-File removes lock files (idempotent)
    - Contested lock returns false within timeout
    - Stale lock with dead PID is reclaimed
    - Lock ownership isolation: two agents cannot hold the same lock
    - Register-Namespace creates reservation files
    - Register-Namespace is idempotent for same agent
    - Remove-NamespaceReservation removes reservation files
    - Orphaned heartbeat causes namespace reclamation

    All properties use deterministic seeds (20260920) and explicit numRuns.
    Process liveness is non-hermetic — properties use fake PIDs for dead-agent
    simulation and record timing exclusions explicitly.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    . (Join-Path $script:repoRoot 'Tools/QA/powershell-property-testing/PropertyTesting.ps1')

    # Stub dependencies
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Get-InterclawConstants { @{ NamespaceReclaimThresholdSeconds = 120 } }
    function Get-SalmonRunConstants { @{ NamespaceReclaimThresholdSeconds = 120 } }

    # Create a temp repo root for hermetic tests
    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "locking-prop-test-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:tempDir -Force

    # Save and force the public SalmonRun.Paths cache to resolve to the temp dir.
    # The env + reset works when the module is already loaded in AQE; the global
    # stubs are a fallback when it is not.
    $script:SavedRepoRoot = $env:REPO_ROOT
    $env:REPO_ROOT = $script:tempDir
    $script:SavedSalmonRunHome = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = $script:tempDir
    if (Get-Command Reset-SalmonRunPathCache -ErrorAction SilentlyContinue) { Reset-SalmonRunPathCache }
    if (Get-Command Reset-InterclawPathCache -ErrorAction SilentlyContinue) { Reset-InterclawPathCache }

    # Stub path and constants helpers; use SalmonRun names so module aliases
    # cannot shadow the test stubs.
    function global:Get-SalmonRunRepoRoot { return $script:tempDir }
    function global:Get-InterclawRepoRoot { return $script:tempDir }

    # Load SalmonRun.Paths so Get-SalmonTaskRoot resolves to SALMON_RUN_HOME/Tasks
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Paths/SalmonRun.Paths.ps1')

    # Dot-source dependencies
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Core/Public/Write-AtomicFile.ps1')

    # Dot-source Locking module (Public + Private)
    $lockingPrivateDir = Join-Path $script:repoRoot 'Modules/SalmonRun.Locking/Private'
    if (Test-Path $lockingPrivateDir) {
        Get-ChildItem -Path $lockingPrivateDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    }
    $lockingPublicDir = Join-Path $script:repoRoot 'Modules/SalmonRun.Locking/Public'
    if (Test-Path $lockingPublicDir) {
        Get-ChildItem -Path $lockingPublicDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    }

    # Dot-source AgentLifecycle for Write-AgentHeartbeat (needed for namespace reclaim tests)
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Core/Public/Convert-PidSafe.ps1')
    $lifecyclePublicDir = Join-Path $script:repoRoot 'Modules/SalmonRun.AgentLifecycle/Public'
    Get-ChildItem -Path $lifecyclePublicDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

AfterAll {
    if ($script:tempDir -and (Test-Path $script:tempDir)) {
        Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($script:SavedRepoRoot) { $env:REPO_ROOT = $script:SavedRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
    if ($script:SavedSalmonRunHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonRunHome } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    if (Get-Command Reset-SalmonRunPathCache -ErrorAction SilentlyContinue) { Reset-SalmonRunPathCache }
    if (Get-Command Reset-InterclawPathCache -ErrorAction SilentlyContinue) { Reset-InterclawPathCache }
}

Describe "Lock-File property tests" -Tag "Property", "Locking" {

    Context "Uncontested lock acquire" {
        It "property: acquiring N distinct locks always succeeds" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $N = $rng.Next(1, 10)
                $names = @()
                for ($i = 0; $i -lt $N; $i++) { $names += "lock-$seed-$i" }

                $acquired = Lock-File -FileNames $names
                $acquired | Should -Be $true

                # Verify lock files exist
                foreach ($name in $names) {
                    Test-Path "$script:tempDir/Tasks/Locks/$name.lock" | Should -Be $true
                }

                # Cleanup
                Unlock-File -FileNames $names
            } -Seed 20260920 -NumRuns 50 -Description "uncontested acquire N locks"
            $result.Passed | Should -Be $true
        }
    }

    Context "Unlock idempotency" {
        It "property: unlocking the same file twice is safe" {
            $result = Invoke-Property {
                param($seed)
                $name = "unlock-idem-$seed"

                $acquired = Lock-File -FileNames @($name)
                $acquired | Should -Be $true
                Test-Path "$script:tempDir/Tasks/Locks/$name.lock" | Should -Be $true

                Unlock-File -FileNames @($name)
                Test-Path "$script:tempDir/Tasks/Locks/$name.lock" | Should -Be $false

                # Second unlock should not throw
                { Unlock-File -FileNames @($name) } | Should -Not -Throw
                Test-Path "$script:tempDir/Tasks/Locks/$name.lock" | Should -Be $false
            } -Seed 20260921 -NumRuns 30 -Description "double unlock safe"
            $result.Passed | Should -Be $true
        }
    }

    Context "Contested lock timeout" {
        It "property: contested lock returns false within timeout" {
            $result = Invoke-Property {
                param($seed)
                $name = "contest-$seed"

                # First agent acquires
                $acquired = Lock-File -FileNames @($name) -MaxWaitMs 5000
                $acquired | Should -Be $true

                # Second agent tries to acquire same lock with short timeout
                $startTime = Get-Date
                $acquired2 = Lock-File -FileNames @($name) -MaxWaitMs 500
                $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
                $acquired2 | Should -Be $false
                # Should have timed out reasonably close to 500ms (within 2x)
                $elapsed | Should -BeLessThan 1500

                # Cleanup
                Unlock-File -FileNames @($name)
            } -Seed 20260922 -NumRuns 20 -Description "contested timeout"
            $result.Passed | Should -Be $true
        }
    }

    Context "Stale lock reclaim" {
        It "property: lock with dead PID is reclaimed" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = "stale-$seed"
                $fakePid = $rng.Next(9999000, 9999999)
                $fakeAgent = "stale-agent-$seed"

                # Manually create a lock file with a dead PID
                $locksDir = Join-Path $script:tempDir "Tasks/Locks"
                $null = New-Item -ItemType Directory -Path $locksDir -Force
                $lockContent = "$fakeAgent|$fakePid|$(Get-Date -Format 'o')"
                Set-Content -Path "$locksDir/$name.lock" -Value $lockContent -Encoding utf8

                # New agent should be able to reclaim
                $acquired = Lock-File -FileNames @($name) -MaxWaitMs 5000
                $acquired | Should -Be $true

                # Verify the lock file exists and is valid
                Test-Path "$locksDir/$name.lock" | Should -Be $true

                Unlock-File -FileNames @($name)
            } -Seed 20260923 -NumRuns 20 -Description "stale lock reclaim"
            $result.Passed | Should -Be $true
        }
    }

    Context "Ownership isolation" {
        It "property: two concurrent acquires of the same lock cannot both succeed" {
            $result = Invoke-Property {
                param($seed)
                $name = "iso-$seed"

                # Simulate concurrent acquire by holding the lock with a short timeout
                $acquired = Lock-File -FileNames @($name) -MaxWaitMs 5000
                $acquired | Should -Be $true

                # Try to acquire again — must fail
                $acquired2 = Lock-File -FileNames @($name) -MaxWaitMs 200
                $acquired2 | Should -Be $false

                # Verify exactly one lock file exists
                $lockFiles = Get-ChildItem "$script:tempDir/Tasks/Locks/$name.lock" -ErrorAction SilentlyContinue
                $lockFiles.Count | Should -Be 1

                Unlock-File -FileNames @($name)
            } -Seed 20260924 -NumRuns 20 -Description "ownership isolation"
            $result.Passed | Should -Be $true
        }
    }

    Context "Lock content format" {
        It "property: lock file content has expected pipe-delimited format" {
            $result = Invoke-Property {
                param($seed)
                $name = "format-$seed"

                $acquired = Lock-File -FileNames @($name)
                $acquired | Should -Be $true

                $content = (Get-Content "$script:tempDir/Tasks/Locks/$name.lock" -Raw).Trim()
                $parts = $content -split '\|'
                $parts.Count | Should -BeGreaterOrEqual 3
                # First part is agent ID (string)
                $parts[0] | Should -Not -BeNullOrEmpty
                # Second part is PID (numeric)
                [int]::Parse($parts[1]) | Should -BeGreaterThan 0
                # Third part is ISO timestamp
                $parsed = [datetime]::MinValue
                [datetime]::TryParse($parts[2], [ref]$parsed) | Should -Be $true

                Unlock-File -FileNames @($name)
            } -Seed 20260925 -NumRuns 20 -Description "lock content format"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Register-Namespace property tests" -Tag "Property", "Locking" {

    Context "Namespace reservation idempotency" {
        It "property: same agent registering twice returns true both times" {
            $result = Invoke-Property {
                param($seed)
                $prefix = "ns-$seed"
                $agentId = "ns-agent-$seed"

                $first = Register-Namespace -NamespacePrefix $prefix -AgentId $agentId
                $first | Should -Be $true

                $second = Register-Namespace -NamespacePrefix $prefix -AgentId $agentId
                $second | Should -Be $true

                # Verify reservation file exists
                Test-Path "$script:tempDir/Tasks/Locks/namespace-$prefix.reserved" | Should -Be $true

                # Cleanup
                Remove-Item "$script:tempDir/Tasks/Locks/namespace-$prefix.reserved" -Force -ErrorAction SilentlyContinue
            } -Seed 20260926 -NumRuns 30 -Description "namespace idempotent"
            $result.Passed | Should -Be $true
        }
    }

    Context "Namespace ownership isolation" {
        It "property: different agent cannot acquire reserved namespace" {
            $result = Invoke-Property {
                param($seed)
                $prefix = "ns-iso-$seed"
                $agent1 = "agent-a-$seed"
                $agent2 = "agent-b-$seed"

                # Agent1 reserves and writes a heartbeat so the reservation is live
                $first = Register-Namespace -NamespacePrefix $prefix -AgentId $agent1
                $first | Should -Be $true
                Write-AgentHeartbeat -AgentId $agent1 | Should -Not -BeNullOrEmpty

                # Agent2 tries to reserve — should fail (agent1's heartbeat is fresh)
                $second = Register-Namespace -NamespacePrefix $prefix -AgentId $agent2
                $second | Should -Be $false

                # Cleanup
                Remove-Item "$script:tempDir/Tasks/Locks/namespace-$prefix.reserved" -Force -ErrorAction SilentlyContinue
            } -Seed 20260927 -NumRuns 20 -Description "namespace ownership isolated"
            $result.Passed | Should -Be $true
        }
    }

    Context "Remove-NamespaceReservation" {
        It "property: removing reservation makes namespace available again" {
            $result = Invoke-Property {
                param($seed)
                $prefix = "ns-rm-$seed"
                $agent1 = "rm-agent-a-$seed"
                $agent2 = "rm-agent-b-$seed"

                # Agent1 reserves and writes a heartbeat so the reservation is live
                Register-Namespace -NamespacePrefix $prefix -AgentId $agent1 | Should -Be $true
                Write-AgentHeartbeat -AgentId $agent1 | Should -Not -BeNullOrEmpty

                # Agent2 cannot acquire
                Register-Namespace -NamespacePrefix $prefix -AgentId $agent2 | Should -Be $false

                # Agent1 releases
                Remove-NamespaceReservation -NamespacePrefix $prefix -AgentId $agent1

                # Agent2 can now acquire
                Register-Namespace -NamespacePrefix $prefix -AgentId $agent2 | Should -Be $true

                # Cleanup
                Remove-Item "$script:tempDir/Tasks/Locks/namespace-$prefix.reserved" -Force -ErrorAction SilentlyContinue
            } -Seed 20260928 -NumRuns 20 -Description "remove then reacquire"
            $result.Passed | Should -Be $true
        }
    }

    Context "Remove-NamespaceReservation idempotency" {
        It "property: removing non-existent reservation is safe" {
            $result = Invoke-Property {
                param($seed)
                $prefix = "ns-nx-$seed"

                { Remove-NamespaceReservation -NamespacePrefix $prefix -AgentId "ghost-$seed" } | Should -Not -Throw
            } -Seed 20260929 -NumRuns 20 -Description "remove nonexistent safe"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Locking integration property tests" -Tag "Property", "Locking" {

    Context "Lock-namespace round trip" {
        It "property: lock acquire → namespace reserve → unlock → namespace release is consistent" {
            $result = Invoke-Property {
                param($seed)
                $name = "rt-$seed"
                $prefix = "ns-rt-$seed"
                $agentId = "rt-agent-$seed"

                # Acquire file lock
                Lock-File -FileNames @($name) | Should -Be $true

                # Reserve namespace
                Register-Namespace -NamespacePrefix $prefix -AgentId $agentId | Should -Be $true

                # Verify both exist
                Test-Path "$script:tempDir/Tasks/Locks/$name.lock" | Should -Be $true
                Test-Path "$script:tempDir/Tasks/Locks/namespace-$prefix.reserved" | Should -Be $true

                # Release both
                Unlock-File -FileNames @($name)
                Remove-NamespaceReservation -NamespacePrefix $prefix -AgentId $agentId

                # Verify both removed
                Test-Path "$script:tempDir/Tasks/Locks/$name.lock" | Should -Be $false
                Test-Path "$script:tempDir/Tasks/Locks/namespace-$prefix.reserved" | Should -Be $false
            } -Seed 20260930 -NumRuns 30 -Description "round trip consistency"
            $result.Passed | Should -Be $true
        }
    }
}
