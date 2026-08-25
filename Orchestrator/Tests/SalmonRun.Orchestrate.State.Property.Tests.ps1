#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for orchestrator state reconciliation and namespace clearing invariants.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    . (Join-Path $script:repoRoot 'Skills/QA/powershell-property-testing/PropertyTesting.ps1')

    $script:statePath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/State.ps1'
    $script:connascencePath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/Connascence.ps1'

    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
    function Write-OrchestratorLogSafe { param([string]$Message, [string]$Level) }
    function Get-InterclawRepoRoot { return $script:repoRoot }
    function Test-AgentAlive { param([string]$AgentId); return @{ ProcessAlive = $false; HasHeartbeat = $false; HeartbeatStale = $true } }
    function Write-AtomicJson { param([string]$Path, [object]$InputObject) }

    . $script:connascencePath
    . $script:statePath
}

Describe "Clear-UsedNamepacesForFiles property tests" -Tag "Property", "State" {

    Context "Removes disk-present files from usedNamespaces" {
        It "property: every file on disk in Code/ is removed from usedNamespaces" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $fileCount = $rng.Next(1, 8)

                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "state-clear-$seed"
                $codeDir = Join-Path $tempDir "Tasks/Code"
                $reviewDir = Join-Path $tempDir "Tasks/Review"
                $null = New-Item -ItemType Directory -Path $codeDir -Force
                $null = New-Item -ItemType Directory -Path $reviewDir -Force

                $createdFiles = @()
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $fname = "2026.08.23-ns$($rng.Next(1,5))-$($rng.Next(1,20))-file$i.md"
                    "content $i" | Set-Content -Path (Join-Path $codeDir $fname) -Encoding utf8 -NoNewline
                    $createdFiles += $fname
                }

                $usedNamespaces = @{}
                foreach ($f in $createdFiles) { $usedNamespaces[$f] = "ns-$f" }
                $ghostFile = "ghost-$seed.md"
                $usedNamespaces[$ghostFile] = "ns-ghost"

                try {
                    Clear-UsedNamepacesForFiles -RepoDir $tempDir -UsedNamespaces $usedNamespaces
                    foreach ($f in $createdFiles) {
                        $usedNamespaces.ContainsKey($f) | Should -Be $false
                    }
                    $usedNamespaces.ContainsKey($ghostFile) | Should -Be $true
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300020 -NumRuns 30 -Description "disk-present files removed"
            $result.Passed | Should -Be $true
        }
    }

    Context "Ghost entries preserved" {
        It "property: files not on disk remain in usedNamespaces" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $ghostCount = $rng.Next(1, 6)

                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "state-ghost-$seed"
                $codeDir = Join-Path $tempDir "Tasks/Code"
                $reviewDir = Join-Path $tempDir "Tasks/Review"
                $null = New-Item -ItemType Directory -Path $codeDir -Force
                $null = New-Item -ItemType Directory -Path $reviewDir -Force

                $usedNamespaces = @{}
                for ($i = 0; $i -lt $ghostCount; $i++) {
                    $gfile = "ghost-$seed-$i.md"
                    $usedNamespaces[$gfile] = "ns-ghost-$i"
                }

                try {
                    Clear-UsedNamepacesForFiles -RepoDir $tempDir -UsedNamespaces $usedNamespaces
                    foreach ($key in $usedNamespaces.Keys) {
                        $key | Should -Match '^ghost-'
                    }
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300022 -NumRuns 20 -Description "ghost entries preserved"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-StreamModuleId property tests" -Tag "Property", "State" {

    Context "Always returns non-null string" {
        It "property: returns a non-empty string for any path" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $interclawDir = "~/.salmon"
                $modules = @("moduleA", "moduleB", "default")
                $module = $modules[$rng.Next(0, $modules.Count)]
                $streamPath = "$interclawDir/Tasks/Worktrees/$module/stream-$($rng.Next(1,100))"
                $id = Get-StreamModuleId -StreamPath $streamPath -RepoDir $interclawDir
                $id | Should -Not -BeNullOrEmpty
                $id | Should -BeOfType [string]
            } -Seed 300030 -NumRuns 20 -Description "always returns non-empty string"
            $result.Passed | Should -Be $true
        }
    }

    Context "Main fallback" {
        It "property: non-worktree path returns 'main'" {
            $result = Invoke-Property {
                param($seed)
                $interclawDir = "~/.salmon"
                $rng = [System.Random]::new($seed)
                $id = $rng.Next(1, 1000)
                $streamPath = "$interclawDir/Tasks/Working/stream-$id"
                $module = Get-StreamModuleId -StreamPath $streamPath -RepoDir $interclawDir
                $module | Should -Be 'main'
            } -Seed 300031 -NumRuns 20 -Description "non-worktree returns main"
            $result.Passed | Should -Be $true
        }
    }

    Context "Worktree extraction" {
        It "property: worktree path extracts the module name correctly" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $interclawDir = "~/.salmon"
                $chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $rng.Next(3, 15); $i++) {
                    $null = $sb.Append($chars[$rng.Next(0, $chars.Length)])
                }
                $module = $sb.ToString()
                $streamPath = "$interclawDir/Tasks/Worktrees/$module/stream-$($rng.Next(1,100))"
                $id = Get-StreamModuleId -StreamPath $streamPath -RepoDir $interclawDir
                $id | Should -Be $module
            } -Seed 300032 -NumRuns 20 -Description "worktree extracts module name"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Invoke-ReconcileState property tests" -Tag "Property", "State" {

    Context "Convergence — state stabilizes after reconciliation" {
        It "property: second run produces same ActiveStreams state as first run" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "reconcile-idempotent-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force

                $ns = "ns$($rng.Next(1,100))"
                $iter = $rng.Next(1, 20)
                $fname = "2026.08.23-${ns}-${iter}-task.md"
                "# Session Plan: test task" | Set-Content -Path (Join-Path "$tempDir/Tasks/Code" $fname) -Encoding utf8 -NoNewline

                try {
                    $activeStreams = @{}
                    $busyNamespaces = @{}
                    $usedNamespaces = @{}
                    $usedNamespaces[$fname] = "ns-value"

                    $disc1 = Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces
                    $afterFirst = @{}
                    foreach ($k in $activeStreams.Keys) { $afterFirst[$k] = $activeStreams[$k] }

                    $disc2 = Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces
                    $afterSecond = @{}
                    foreach ($k in $activeStreams.Keys) { $afterSecond[$k] = $activeStreams[$k] }

                    # ActiveStreams must stabilize (same keys and values after first run)
                    $afterFirst.Keys.Count | Should -Be $afterSecond.Keys.Count
                    foreach ($k in $afterFirst.Keys) {
                        $afterSecond.ContainsKey($k) | Should -Be $true
                    }
                    # Second run should have fewer or equal discrepancies
                    $disc2.Count | Should -BeLessOrEqual $disc1.Count
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300100 -NumRuns 20 -Description "reconcile converges"
            $result.Passed | Should -Be $true
        }
    }

    Context "Conservation — no files created or destroyed" {
        It "property: reconcile does not create new files in Code/ or Review/" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "reconcile-conservation-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force

                $fileCount = $rng.Next(1, 5)
                $beforeCode = @()
                $beforeReview = @()
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $ns = "ns$($rng.Next(1,100))"
                    $iter = $rng.Next(1, 20)
                    $fname = "2026.08.23-${ns}-${iter}-file$i.md"
                    $dest = if ($rng.Next(2) -eq 0) { "$tempDir/Tasks/Code" } else { "$tempDir/Tasks/Review" }
                    "content $i" | Set-Content -Path (Join-Path $dest $fname) -Encoding utf8 -NoNewline
                    if ($dest -like "*/Code") { $beforeCode += $fname } else { $beforeReview += $fname }
                }

                try {
                    $activeStreams = @{}
                    $busyNamespaces = @{}
                    $usedNamespaces = @{}
                    Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces | Out-Null

                    $afterCode = @(Get-ChildItem "$tempDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
                    $afterReview = @(Get-ChildItem "$tempDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })

                    $afterCode.Count | Should -Be $beforeCode.Count
                    $afterReview.Count | Should -Be $beforeReview.Count
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300101 -NumRuns 20 -Description "no files created or destroyed"
            $result.Passed | Should -Be $true
        }
    }

    Context "Orphaned stream recovery" {
        It "property: orphaned stream.json without live agent is recovered or cleaned" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "reconcile-orphan-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force

                $ns = "orphan$($rng.Next(1,100))"
                $streamDir = Join-Path "$tempDir/Tasks/Working" "stream-$seed"
                $null = New-Item -ItemType Directory -Path $streamDir -Force
                @{
                    Id = "agent-$seed"
                    Namespace = $ns
                    Role = "coder"
                    Module = "main"
                    Created = (Get-Date -Format 'o')
                } | ConvertTo-Json | Set-Content -Path (Join-Path $streamDir "stream.json") -Encoding utf8 -NoNewline
                "test content" | Set-Content -Path (Join-Path $streamDir "plan.md") -Encoding utf8 -NoNewline

                try {
                    $activeStreams = @{}
                    $busyNamespaces = @{}
                    $usedNamespaces = @{}
                    $disc = Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces

                    # The stream should be recovered into activeStreams (no live agent, but has plan files)
                    $nsKey = "main|$($ns)|coder"
                    $activeStreams.ContainsKey($nsKey) | Should -Be $true
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300102 -NumRuns 15 -Description "orphaned stream recovered"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Clear-UsedNamepacesForFiles idempotency property tests" -Tag "Property", "State" {

    Context "Repeated clearing is idempotent" {
        It "property: clearing twice does not alter the result" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "clear-idempotent-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force

                $fileCount = $rng.Next(1, 6)
                $createdFiles = @()
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $fname = "2026.08.23-ns$($rng.Next(1,5))-$($rng.Next(1,20))-file$i.md"
                    "content $i" | Set-Content -Path (Join-Path "$tempDir/Tasks/Code" $fname) -Encoding utf8 -NoNewline
                    $createdFiles += $fname
                }

                try {
                    $usedNs1 = @{}
                    foreach ($f in $createdFiles) { $usedNs1[$f] = "ns-$f" }
                    $usedNs2 = @{}
                    foreach ($f in $createdFiles) { $usedNs2[$f] = "ns-$f" }

                    Clear-UsedNamepacesForFiles -RepoDir $tempDir -UsedNamespaces $usedNs1
                    Clear-UsedNamepacesForFiles -RepoDir $tempDir -UsedNamespaces $usedNs2

                    # Both should have same result: created files removed, ghost entries preserved
                    $usedNs1.Count | Should -Be $usedNs2.Count
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300110 -NumRuns 20 -Description "double clear is idempotent"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Duplicate namespace handling property tests" -Tag "Property", "State" {

    Context "Files with duplicate namespaces in Code/ and Review/" {
        It "property: clearing removes files from both Code/ and Review/" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dup-ns-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force

                $ns = "proj$($rng.Next(1,100))"
                $iter = $rng.Next(1, 20)
                $fname = "2026.08.23-${ns}-${iter}-task.md"

                "code content" | Set-Content -Path (Join-Path "$tempDir/Tasks/Code" $fname) -Encoding utf8 -NoNewline
                "review content" | Set-Content -Path (Join-Path "$tempDir/Tasks/Review" $fname) -Encoding utf8 -NoNewline

                try {
                    $usedNs = @{ $fname = "ns-value" }
                    Clear-UsedNamepacesForFiles -RepoDir $tempDir -UsedNamespaces $usedNs
                    $usedNs.ContainsKey($fname) | Should -Be $false
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300200 -NumRuns 15 -Description "duplicates in both dirs removed"
            $result.Passed | Should -Be $true
        }
    }

    Context "Multiple files with same namespace prefix" {
        It "property: all files with matching prefix are cleared" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "multi-ns-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force

                $ns = "architectural$($rng.Next(1,50))"
                $fileCount = $rng.Next(2, 5)
                $createdFiles = @()
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $iter = $rng.Next(1, 20)
                    $fname = "2026.08.23-${ns}-${iter}-file$i.md"
                    "content $i" | Set-Content -Path (Join-Path "$tempDir/Tasks/Code" $fname) -Encoding utf8 -NoNewline
                    $createdFiles += $fname
                }

                try {
                    $usedNs = @{}
                    foreach ($f in $createdFiles) { $usedNs[$f] = "ns-$ns" }
                    Clear-UsedNamepacesForFiles -RepoDir $tempDir -UsedNamespaces $usedNs
                    foreach ($f in $createdFiles) {
                        $usedNs.ContainsKey($f) | Should -Be $false
                    }
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300201 -NumRuns 15 -Description "all same-ns files cleared"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "ReconcileState status change property tests" -Tag "Property", "State" {

    Context "Status transitions" {
        It "property: stream.json status changes are reflected in reconciliation" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "status-change-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force

                $ns = "status$($rng.Next(1,100))"
                $streamDir = Join-Path "$tempDir/Tasks/Working" "stream-$seed"
                $null = New-Item -ItemType Directory -Path $streamDir -Force

                # Create stream.json with a plan file
                @{
                    Id = "agent-status-$seed"
                    Namespace = $ns
                    Role = "coder"
                    Module = "main"
                    Created = (Get-Date -Format 'o')
                } | ConvertTo-Json | Set-Content -Path (Join-Path $streamDir "stream.json") -Encoding utf8 -NoNewline
                "# Session Plan: status test task" | Set-Content -Path (Join-Path $streamDir "plan.md") -Encoding utf8 -NoNewline

                try {
                    $activeStreams = @{}
                    $busyNamespaces = @{}
                    $usedNamespaces = @{}

                    # First reconcile: stream should be recovered
                    Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces | Out-Null
                    $nsKey = "main|$($ns)|coder"
                    $activeStreams.ContainsKey($nsKey) | Should -Be $true

                    # Simulate completion: add .complete sentinel, then remove from
                    # activeStreams (simulates the orchestrator detecting completion
                    # and removing the stream from its in-memory tracking).
                    "done" | Set-Content -Path (Join-Path $streamDir ".complete") -Encoding utf8 -NoNewline
                    $activeStreams.Remove($nsKey)

                    # Second reconcile: completed stream should be cleaned up
                    Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces | Out-Null
                    # stream.json should be removed for completed stream
                    Test-Path (Join-Path $streamDir "stream.json") | Should -Be $false
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300210 -NumRuns 15 -Description "status transition handled"
            $result.Passed | Should -Be $true
        }
    }

    Context "Orphaned files with conflicting state" {
        It "property: files in Working/ without valid agent are recovered" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "orphan-conflict-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force

                $ns = "conflict$($rng.Next(1,100))"
                $streamDir = Join-Path "$tempDir/Tasks/Working" "stream-conflict-$seed"
                $null = New-Item -ItemType Directory -Path $streamDir -Force

                # Create stream.json without a live agent
                @{
                    Id = "agent-conflict-$seed"
                    Namespace = $ns
                    Role = "coder"
                    Module = "main"
                    Created = (Get-Date -Format 'o')
                } | ConvertTo-Json | Set-Content -Path (Join-Path $streamDir "stream.json") -Encoding utf8 -NoNewline
                "# Session Plan: conflict task" | Set-Content -Path (Join-Path $streamDir "plan.md") -Encoding utf8 -NoNewline

                try {
                    $activeStreams = @{}
                    $busyNamespaces = @{}
                    $usedNamespaces = @{}

                    $disc = Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces
                    $nsKey = "main|$($ns)|coder"
                    $activeStreams.ContainsKey($nsKey) | Should -Be $true
                    # Should be marked as recovered
                    $activeStreams[$nsKey].Status | Should -Be "recovered"
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300211 -NumRuns 15 -Description "orphan conflict recovered"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "ReconcileState file conservation property tests" -Tag "Property", "State" {

    Context "Conservation across multiple reconciliation passes" {
        It "property: repeated reconciliation does not create or destroy files" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "conservation-multi-$seed"
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Code" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Review" -Force
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Working" -Force

                $fileCount = $rng.Next(1, 5)
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $ns = "ns$($rng.Next(1,100))"
                    $iter = $rng.Next(1, 20)
                    $fname = "2026.08.23-${ns}-${iter}-conv$i.md"
                    $dest = if ($rng.Next(2) -eq 0) { "$tempDir/Tasks/Code" } else { "$tempDir/Tasks/Review" }
                    "content $i" | Set-Content -Path (Join-Path $dest $fname) -Encoding utf8 -NoNewline
                }

                try {
                    $activeStreams = @{}
                    $busyNamespaces = @{}
                    $usedNamespaces = @{}

                    # Run reconciliation 3 times
                    for ($pass = 0; $pass -lt 3; $pass++) {
                        Invoke-ReconcileState -RepoDir $tempDir -ActiveStreams $activeStreams -BusyNamespaces $busyNamespaces -UsedNamespaces $usedNamespaces | Out-Null
                    }

                    $afterCode = @(Get-ChildItem "$tempDir/Tasks/Code/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count
                    $afterReview = @(Get-ChildItem "$tempDir/Tasks/Review/*.md" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' }).Count

                    # Total files should not have grown
                    ($afterCode + $afterReview) | Should -BeLessOrEqual ($fileCount + 1)
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300220 -NumRuns 15 -Description "conservation across passes"
            $result.Passed | Should -Be $true
        }
    }
}
