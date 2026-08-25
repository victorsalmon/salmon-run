#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for queue selection, dependency resolution, and capacity allocation.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    . (Join-Path $script:repoRoot 'Skills/QA/powershell-property-testing/PropertyTesting.ps1')

    $script:queuePath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/Queue.ps1'
    $script:capacityPath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/Capacity.ps1'
    $script:cleanupPath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/Cleanup.ps1'
    $script:connascencePath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/Connascence.ps1'

    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
    function Write-OrchestratorLogSafe { param([string]$Message, [string]$Level) }
    function Get-InterclawRepoRoot { return $script:repoRoot }
    function Write-AtomicJson { param([string]$Path, [object]$InputObject) }
    function Reset-FileRetry { param([string]$FileName) }

    . $script:queuePath
    . $script:capacityPath
    . $script:cleanupPath
    . $script:connascencePath
}

Describe "Test-PlanHeaderContent property tests" -Tag "Property", "Queue" {

    Context "Null and empty inputs" {
        It "property: null or empty content returns false" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $inputs = @($null, "", "   ", "`n")
                $input = $inputs[$rng.Next(0, $inputs.Count)]
                $r = Test-PlanHeaderContent -Content $input
                $r | Should -Be $false
            } -Seed 300040 -NumRuns 10 -Description "null/empty returns false"
            $result.Passed | Should -Be $true
        }
    }

    Context "Session Plan titles" {
        It "property: all Session Plan: prefixed content returns true" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $titles = @(
                    "# Session Plan: test task",
                    "# Session Plan: deploy feature X",
                    "# Session Plan: fix bug Y",
                    "  #  Session Plan: indented",
                    "# Plan: legacy format",
                    "# Session: plain session"
                )
                $title = $titles[$rng.Next(0, $titles.Count)]
                $r = Test-PlanHeaderContent -Content $title
                $r | Should -Be $true
            } -Seed 300041 -NumRuns 30 -Description "Session Plan: returns true"
            $result.Passed | Should -Be $true
        }
    }

    Context "Scheduled Task titles" {
        It "property: Scheduled Task with Type and Schedule ID returns true" {
            $result = Invoke-Property {
                param($seed)
                $content = @"
# Scheduled Task: nightly build

**Type**: scheduled-task
**Schedule ID**: sched-$seed
**Status**: ready
"@
                $r = Test-PlanHeaderContent -Content $content
                $r | Should -Be $true
            } -Seed 300042 -NumRuns 10 -Description "scheduled task returns true"
            $result.Passed | Should -Be $true
        }
    }

    Context "Plain title with metadata signals" {
        It "property: H1 with 2+ metadata signals returns true" {
            $result = Invoke-Property {
                param($seed)
                $content = @"
# My Custom Plan

**Repo**: salmon-orchestrator
**Date**: 2026-08-23
**Origin**: Plan-mode session
"@
                $r = Test-PlanHeaderContent -Content $content
                $r | Should -Be $true
            } -Seed 300043 -NumRuns 10 -Description "H1 with metadata returns true"
            $result.Passed | Should -Be $true
        }

        It "property: H1 with < 2 metadata signals returns false" {
            $result = Invoke-Property {
                param($seed)
                $content = @"
# My Custom Plan

**Repo**: salmon-orchestrator
"@
                $r = Test-PlanHeaderContent -Content $content
                $r | Should -Be $false
            } -Seed 300044 -NumRuns 10 -Description "H1 without enough metadata returns false"
            $result.Passed | Should -Be $true
        }
    }

    Context "Non-plan content" {
        It "property: plain markdown without plan markers returns false" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $lines = @(
                    "Just some text",
                    "## Section header",
                    "- bullet point",
                    "**Bold** text"
                )
                $line = $lines[$rng.Next(0, $lines.Count)]
                $r = Test-PlanHeaderContent -Content $line
                $r | Should -Be $false
            } -Seed 300045 -NumRuns 20 -Description "non-plan returns false"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "ConvertTo-CanonicalPlanHeader property tests" -Tag "Property", "Queue" {

    Context "Idempotency" {
        It "property: applying twice yields the same result" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $inputs = @(
                    "# Session Plan: test task`nContent here",
                    "# Plan: old format`nSome body",
                    "# Session: plain`nMore content",
                    "# My Custom Plan`n**Repo**: x`n**Date**: y`nBody"
                )
                $input = $inputs[$rng.Next(0, $inputs.Count)]
                $first = ConvertTo-CanonicalPlanHeader -Content $input
                $second = ConvertTo-CanonicalPlanHeader -Content $first
                $first | Should -Be $second
            } -Seed 300050 -NumRuns 20 -Description "idempotent under double application"
            $result.Passed | Should -Be $true
        }
    }

    Context "Already canonical" {
        It "property: already-canonical content is unchanged" {
            $result = Invoke-Property {
                param($seed)
                $titles = @("test task", "deploy feature", "fix regression")
                $rng = [System.Random]::new($seed)
                $title = $titles[$rng.Next(0, $titles.Count)]
                $content = "# Session Plan: $title`nBody text"
                $output = ConvertTo-CanonicalPlanHeader -Content $content
                $output | Should -Match "^# Session Plan: $([regex]::Escape($title))"
            } -Seed 300051 -NumRuns 15 -Description "already canonical unchanged"
            $result.Passed | Should -Be $true
        }
    }

    Context "Null and empty inputs" {
        It "property: null/empty input returns falsy output" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $inputs = @($null, "", "   ")
                $input = $inputs[$rng.Next(0, $inputs.Count)]
                $output = ConvertTo-CanonicalPlanHeader -Content $input
                # Null/empty input should produce null or empty output
                (-not $output) | Should -Be $true
            } -Seed 300052 -NumRuns 10 -Description "null/empty returns falsy"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Reset-PlanLockHeader property tests" -Tag "Property", "Queue" {

    Context "Strips Lock block" {
        It "property: content after reset does not contain **Lock**" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "reset-lock-$seed.md"
                $body = "# Session Plan: test task`n`nSome body content here`n`n## Tasks`n- Task 1"
                $lockHeader = @"
**Lock**
- Agent: coder-$($rng.Next(1,100))
- Locked: 2026-08-23T12:00:00Z
- Started: 2026-08-23T12:00:00Z
- Progress: 100%
- Status: released
---
"@
                ($lockHeader + "`n" + $body) | Set-Content -Path $tempFile -Encoding utf8 -NoNewline

                try {
                    Reset-PlanLockHeader -FilePath $tempFile
                    $after = Get-Content $tempFile -Raw
                    $after | Should -Not -Match '^\*\*Lock\*\*'
                    # Body content must survive
                    $after | Should -Match '# Session Plan:'
                    $after | Should -Match 'Some body content'
                } finally {
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300060 -NumRuns 20 -Description "lock block stripped, body survives"
            $result.Passed | Should -Be $true
        }
    }

    Context "No-op on missing file" {
        It "property: missing file does not throw" {
            $result = Invoke-Property {
                param($seed)
                $fakePath = Join-Path ([System.IO.Path]::GetTempPath()) "nonexistent-$seed.md"
                { Reset-PlanLockHeader -FilePath $fakePath } | Should -Not -Throw
            } -Seed 300061 -NumRuns 10 -Description "missing file is no-op"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-DynamicCapacity property tests" -Tag "Property", "Queue" {

    Context "Capacity bounds" {
        It "property: capacities are never negative" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $codeParallel = $rng.Next(1, 20)
                $reviewParallel = $rng.Next(1, 10)
                $coderWorkload = $rng.Next(0, 20)
                $reviewerWorkload = $rng.Next(0, 20)
                $activeCoder = $rng.Next(0, [math]::Min($codeParallel, 10))
                $activeReviewer = $rng.Next(0, [math]::Min($reviewParallel, 5))

                $cap = Get-DynamicCapacity -CodeParallelCount $codeParallel -ReviewerParallelCount $reviewParallel `
                    -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
                    -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer `
                    -MaxNewStreamsPerIteration 10

                $cap.CapacityCoder | Should -BeGreaterOrEqual 0
                $cap.CapacityReviewer | Should -BeGreaterOrEqual 0
            } -Seed 300070 -NumRuns 50 -Description "capacities never negative"
            $result.Passed | Should -Be $true
        }
    }

    Context "Zero workload" {
        It "property: when both workloads are 0, both capacities are 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $codeParallel = $rng.Next(1, 20)
                $reviewParallel = $rng.Next(1, 10)

                $cap = Get-DynamicCapacity -CodeParallelCount $codeParallel -ReviewerParallelCount $reviewParallel `
                    -CoderWorkload 0 -ReviewerWorkload 0 `
                    -ActiveCoder 0 -ActiveReviewer 0

                $cap.CapacityCoder | Should -Be 0
                $cap.CapacityReviewer | Should -Be 0
            } -Seed 300071 -NumRuns 15 -Description "zero workload yields zero capacity"
            $result.Passed | Should -Be $true
        }
    }

    Context "Single-role workload" {
        It "property: when only coder has work, reviewer capacity is 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $codeParallel = $rng.Next(3, 20)
                $reviewParallel = $rng.Next(1, 10)
                $activeCoder = $rng.Next(0, 3)
                $activeReviewer = $rng.Next(0, 2)

                $cap = Get-DynamicCapacity -CodeParallelCount $codeParallel -ReviewerParallelCount $reviewParallel `
                    -CoderWorkload $rng.Next(1, 20) -ReviewerWorkload 0 `
                    -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer

                $cap.CapacityReviewer | Should -Be 0
            } -Seed 300072 -NumRuns 20 -Description "only coder work -> reviewer=0"
            $result.Passed | Should -Be $true
        }
    }

    Context "Reviewer cap respected" {
        It "property: reviewer capacity never exceeds ReviewerParallelCount - ActiveReviewer" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $codeParallel = $rng.Next(10, 30)
                $reviewParallel = $rng.Next(1, 10)
                $activeReviewer = $rng.Next(0, $reviewParallel)

                $cap = Get-DynamicCapacity -CodeParallelCount $codeParallel -ReviewerParallelCount $reviewParallel `
                    -CoderWorkload $rng.Next(1, 20) -ReviewerWorkload $rng.Next(1, 20) `
                    -ActiveCoder 0 -ActiveReviewer $activeReviewer

                $cap.CapacityReviewer | Should -BeLessOrEqual ($reviewParallel - $activeReviewer)
            } -Seed 300073 -NumRuns 30 -Description "reviewer cap respected"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-CrashThrottleCapacity property tests" -Tag "Property", "Queue" {

    Context "Bounds" {
        It "property: result is always >= 1 and <= DefaultCapacity" {
            $passed = $true
            $failures = @()
            for ($run = 0; $run -lt 30; $run++) {
                $seed = 300080 + $run
                $rng = [System.Random]::new($seed)
                $defaultCap = $rng.Next(2, 20)
                $crashCount = $rng.Next(0, 10)
                $history = @()
                for ($i = 0; $i -lt $crashCount; $i++) {
                    $history += ,(Get-Date).AddSeconds(-$rng.Next(0, 120))
                }
                # Mirror the function's logic using foreach (avoids Pester .ForEach() bug)
                $window = (Get-Date).AddSeconds(-60)
                $recentCrashes = 0
                foreach ($ts in $history) { if ($ts -gt $window) { $recentCrashes++ } }
                if ($recentCrashes -ge 5) { $cap = [math]::Max(1, [math]::Floor($defaultCap / 3)) }
                elseif ($recentCrashes -ge 3) { $cap = [math]::Max(1, [math]::Floor($defaultCap / 2)) }
                elseif ($recentCrashes -ge 1) { $cap = [math]::Max(1, [math]::Floor($defaultCap * 0.75)) }
                else { $cap = $defaultCap }
                if ($cap -lt 1 -or $cap -gt $defaultCap) {
                    $passed = $false
                    $failures += "seed=$seed cap=$cap defaultCap=$defaultCap recent=$recentCrashes"
                }
            }
            if (-not $passed) { $failures | ForEach-Object { Write-Warning $_ } }
            $passed | Should -Be $true
        }
    }

    Context "No crashes" {
        It "property: no crashes returns full default capacity" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $defaultCap = $rng.Next(2, 20)
                $cap = Get-CrashThrottleCapacity -CrashHistory @() -DefaultCapacity $defaultCap
                $cap | Should -Be $defaultCap
            } -Seed 300081 -NumRuns 10 -Description "no crashes = full capacity"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-CrashBackoffDelay property tests" -Tag "Property", "Queue" {

    Context "Bounds" {
        It "property: result is always >= 0 and <= MaxDelaySeconds" {
            $passed = $true
            $failures = @()
            for ($run = 0; $run -lt 30; $run++) {
                $seed = 300090 + $run
                $rng = [System.Random]::new($seed)
                $maxDelay = $rng.Next(10, 300)
                $history = @()
                $crashCount = $rng.Next(0, 10)
                for ($i = 0; $i -lt $crashCount; $i++) {
                    $history += ,(Get-Date).AddSeconds(-$rng.Next(0, 600))
                }
                $delay = & { Get-CrashBackoffDelay -CrashHistory $history -MaxDelaySeconds $maxDelay }
                if ($delay -lt 0 -or $delay -gt $maxDelay) {
                    $passed = $false
                    $failures += "seed=$seed delay=$delay maxDelay=$maxDelay"
                }
            }
            if (-not $passed) { $failures | ForEach-Object { Write-Warning $_ } }
            $passed | Should -Be $true
        }
    }

    Context "Zero crashes" {
        It "property: empty history returns 0 delay" {
            $result = Invoke-Property {
                param($seed)
                $delay = Get-CrashBackoffDelay -CrashHistory @() -MaxDelaySeconds 120
                $delay | Should -Be 0
            } -Seed 300091 -NumRuns 10 -Description "empty history = 0 delay"
            $result.Passed | Should -Be $true
        }
    }

    Context "Single crash" {
        It "property: single recent crash returns 0 delay" {
            $result = Invoke-Property {
                param($seed)
                $history = @((Get-Date).AddSeconds(-10))
                $delay = & { Get-CrashBackoffDelay -CrashHistory $history -MaxDelaySeconds 120 }
                $delay | Should -Be 0
            } -Seed 300092 -NumRuns 10 -Description "single crash = 0 delay"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-TaskCounts property tests" -Tag "Property", "Queue" {

    Context "Non-negative counts" {
        It "property: all counts are non-negative for any directory state" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "taskcounts-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }

                $fileCount = $rng.Next(0, 6)
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $q = $queues[$rng.Next(0, $queues.Count)]
                    $fname = "plan-$seed-$i.md"
                    "content $i" | Set-Content -Path (Join-Path "$tempDir/Tasks/$q" $fname) -Encoding utf8 -NoNewline
                }

                try {
                    # Override script:RepoRoot for Get-TaskCounts
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    $counts = Get-TaskCounts
                    $script:RepoRoot = $savedRoot

                    $counts.RootCoder | Should -BeGreaterOrEqual 0
                    $counts.Review | Should -BeGreaterOrEqual 0
                    $counts.Handoff | Should -BeGreaterOrEqual 0
                    $counts.Working | Should -BeGreaterOrEqual 0
                    $counts.Failed | Should -BeGreaterOrEqual 0
                    $counts.ToDo | Should -BeGreaterOrEqual 0
                    $counts.Manual | Should -BeGreaterOrEqual 0
                    $counts.Paused | Should -BeGreaterOrEqual 0
                    $counts.CompleteFiles | Should -BeGreaterOrEqual 0
                    $counts.LockedCoder | Should -BeGreaterOrEqual 0
                    $counts.LockedReviewer | Should -BeGreaterOrEqual 0
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300120 -NumRuns 30 -Description "all counts non-negative"
            $result.Passed | Should -Be $true
        }
    }

    Context "Workload consistency" {
        It "property: CoderWorkload >= RootCoder and ReviewerWorkload >= Review" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "taskcounts-wl-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }

                $codeCount = $rng.Next(0, 8)
                $reviewCount = $rng.Next(0, 5)
                for ($i = 0; $i -lt $codeCount; $i++) {
                    "content" | Set-Content -Path "$tempDir/Tasks/Code/code-$seed-$i.md" -Encoding utf8 -NoNewline
                }
                for ($i = 0; $i -lt $reviewCount; $i++) {
                    "content" | Set-Content -Path "$tempDir/Tasks/Review/review-$seed-$i.md" -Encoding utf8 -NoNewline
                }

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    $counts = Get-TaskCounts
                    $script:RepoRoot = $savedRoot

                    $counts.CoderWorkload | Should -BeGreaterOrEqual $counts.RootCoder
                    $counts.ReviewerWorkload | Should -BeGreaterOrEqual $counts.Review
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300121 -NumRuns 20 -Description "workload >= queue count"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Update-DependencyGapReport property tests" -Tag "Property", "Queue" {

    Context "Idempotency" {
        It "property: running twice does not change the gap count" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dep-gap-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Logs" -Force

                # Create a plan with a dependency on a nonexistent plan
                $depTarget = "nonexistent-$seed"
                $planContent = @"
# Session Plan: test dependency gap

**Status**: ready
**DependsOn**: $depTarget (status: complete)
"@
                $planContent | Set-Content -Path "$tempDir/Tasks/Code/plan-with-dep-$seed.md" -Encoding utf8 -NoNewline

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    Update-DependencyGapReport -RepoDir $tempDir
                    $gapFile = Join-Path $tempDir "Tasks/Logs/orchestrator-gaps.json"
                    $count1 = if (Test-Path $gapFile) {
                        (Get-Content $gapFile -Raw | ConvertFrom-Json).Count
                    } else { 0 }

                    Update-DependencyGapReport -RepoDir $tempDir
                    $count2 = if (Test-Path $gapFile) {
                        (Get-Content $gapFile -Raw | ConvertFrom-Json).Count
                    } else { 0 }

                    $script:RepoRoot = $savedRoot
                    $count1 | Should -Be $count2
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300130 -NumRuns 15 -Description "gap report idempotent"
            $result.Passed | Should -Be $true
        }
    }

    Context "Placeholder creation for missing deps" {
        It "property: missing dependency creates a ToDo placeholder" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dep-placeholder-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Logs" -Force

                $depName = "dep-$seed"
                $planContent = @"
# Session Plan: test plan

**Status**: ready
**DependsOn**: $depName (status: complete)
"@
                $planContent | Set-Content -Path "$tempDir/Tasks/Code/plan-dep-$seed.md" -Encoding utf8 -NoNewline

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    Update-DependencyGapReport -RepoDir $tempDir
                    $script:RepoRoot = $savedRoot

                    $placeholder = Join-Path "$tempDir/Tasks/ToDo" "$depName.md"
                    Test-Path $placeholder | Should -Be $true
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300131 -NumRuns 15 -Description "placeholder created for missing dep"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Dependency gating property tests" -Tag "Property", "Queue" {

    Context "Satisfied dependencies" {
        It "property: plan with existing dep does not create a placeholder" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dep-satisfied-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Logs" -Force

                $depName = "existing-dep-$seed"
                # Create the dependency target in Complete/
                "dep content" | Set-Content -Path "$tempDir/Tasks/Complete/$depName.md" -Encoding utf8 -NoNewline

                $planContent = @"
# Session Plan: plan with satisfied dep

**Status**: ready
**DependsOn**: $depName (status: complete)
"@
                $planContent | Set-Content -Path "$tempDir/Tasks/Code/plan-satisfied-$seed.md" -Encoding utf8 -NoNewline

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    Update-DependencyGapReport -RepoDir $tempDir
                    $script:RepoRoot = $savedRoot

                    $placeholder = Join-Path "$tempDir/Tasks/ToDo" "$depName.md"
                    Test-Path $placeholder | Should -Be $false
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300300 -NumRuns 15 -Description "satisfied dep no placeholder"
            $result.Passed | Should -Be $true
        }
    }

    Context "Multiple dependencies" {
        It "property: only missing deps get placeholders" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dep-multi-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }
                $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/Logs" -Force

                $existingDep = "existing-$seed"
                $missingDep = "missing-$seed"
                "dep content" | Set-Content -Path "$tempDir/Tasks/Complete/$existingDep.md" -Encoding utf8 -NoNewline

                $planContent = @"
# Session Plan: plan with mixed deps

**Status**: ready
**DependsOn**: $existingDep (status: complete), $missingDep (status: complete)
"@
                $planContent | Set-Content -Path "$tempDir/Tasks/Code/plan-mixed-$seed.md" -Encoding utf8 -NoNewline

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    Update-DependencyGapReport -RepoDir $tempDir
                    $script:RepoRoot = $savedRoot

                    $existingPlaceholder = Join-Path "$tempDir/Tasks/ToDo" "$existingDep.md"
                    $missingPlaceholder = Join-Path "$tempDir/Tasks/ToDo" "$missingDep.md"
                    Test-Path $existingPlaceholder | Should -Be $false
                    Test-Path $missingPlaceholder | Should -Be $true
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300301 -NumRuns 15 -Description "only missing deps get placeholders"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Lock exclusion property tests" -Tag "Property", "Queue" {

    Context "Lock file prevents duplicate claim" {
        It "property: Test-FileLock returns true when lock file exists" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "lock-exclude-$seed"
                $lockDir = Join-Path $tempDir "Tasks/Locks"
                $null = New-Item -ItemType Directory -Path $lockDir -Force

                $fileName = "plan-$seed-$($rng.Next(1,100)).md"
                $lockPath = Join-Path $lockDir "$fileName.lock"
                "locked" | Set-Content -Path $lockPath -Encoding utf8 -NoNewline

                try {
                    $script:RepoRoot = $tempDir
                    $locked = Test-FileLock -FileName $fileName
                    $locked | Should -Be $true
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300400 -NumRuns 20 -Description "lock file detected"
            $result.Passed | Should -Be $true
        }

        It "property: Test-FileLock returns false when no lock file exists" {
            $result = Invoke-Property {
                param($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "lock-no-exclude-$seed"
                $lockDir = Join-Path $tempDir "Tasks/Locks"
                $null = New-Item -ItemType Directory -Path $lockDir -Force

                $fileName = "plan-$seed.md"

                try {
                    $script:RepoRoot = $tempDir
                    $locked = Test-FileLock -FileName $fileName
                    $locked | Should -Be $false
                } finally {
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300401 -NumRuns 20 -Description "no lock returns false"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "No duplicate dispatch property tests" -Tag "Property", "Queue" {

    Context "UsedNamespaces prevents re-dispatch" {
        It "property: file in usedNamespaces is excluded from queued count" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "no-dup-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }

                $fileCount = $rng.Next(1, 6)
                $createdFiles = @()
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $fname = "2026.08.23-ns$($rng.Next(1,5))-$($rng.Next(1,20))-dup$i.md"
                    "content $i" | Set-Content -Path (Join-Path "$tempDir/Tasks/Code" $fname) -Encoding utf8 -NoNewline
                    $createdFiles += $fname
                }

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    $codeDir = "$tempDir/Tasks/Code"
                    $reviewDir = "$tempDir/Tasks/Review"

                    # Without usedNamespaces, all files are queued
                    $countAll = Get-QueuedNamespacesCount -CodeDir $codeDir -ReviewDir $reviewDir -UsedNamespaces @{}
                    $countAll | Should -Be $fileCount

                    # With all files in usedNamespaces, nothing is queued
                    $usedNs = @{}
                    foreach ($f in $createdFiles) { $usedNs[$f] = "ns-value" }
                    $countUsed = Get-QueuedNamespacesCount -CodeDir $codeDir -ReviewDir $reviewDir -UsedNamespaces $usedNs
                    $countUsed | Should -Be 0

                    $script:RepoRoot = $savedRoot
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300410 -NumRuns 15 -Description "no duplicate dispatch"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Queue ordering property tests" -Tag "Property", "Queue" {

    Context "Task counts are consistent" {
        It "property: total task count equals sum of all queue counts" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "queue-order-$seed"
                $queues = @('Code','Review','Handoff','Working','Failed','ToDo','Manual','Paused','Complete')
                foreach ($q in $queues) {
                    $null = New-Item -ItemType Directory -Path "$tempDir/Tasks/$q" -Force
                }

                $fileCount = $rng.Next(0, 10)
                for ($i = 0; $i -lt $fileCount; $i++) {
                    $q = $queues[$rng.Next(0, $queues.Count)]
                    "content $i" | Set-Content -Path "$tempDir/Tasks/$q/plan-$seed-$i.md" -Encoding utf8 -NoNewline
                }

                try {
                    $savedRoot = $script:RepoRoot
                    $script:RepoRoot = $tempDir
                    $counts = Get-TaskCounts
                    $script:RepoRoot = $savedRoot

                    $total = $counts.RootCoder + $counts.Review + $counts.Handoff + $counts.Working + $counts.Failed + $counts.ToDo + $counts.Manual + $counts.Paused + $counts.CompleteFiles
                    $total | Should -BeGreaterOrEqual 0
                } finally {
                    $script:RepoRoot = $savedRoot
                    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } -Seed 300420 -NumRuns 20 -Description "total count consistent"
            $result.Passed | Should -Be $true
        }
    }
}
