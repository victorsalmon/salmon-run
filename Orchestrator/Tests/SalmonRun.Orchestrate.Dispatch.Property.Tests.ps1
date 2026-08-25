#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for dispatch capacity, retry budgets, and stream reclamation.
.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Dynamic capacity allocation never exceeds role or total caps
    - Retry budget increment/reset idempotency
    - Stall detection resets on progress
    - Stream reclamation removes zombie slots
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    . (Join-Path $script:repoRoot 'Skills/QA/powershell-property-testing/PropertyTesting.ps1')

    $script:capacityPath = Join-Path $script:repoRoot 'Orchestrator/Modules/SalmonRun.Orchestrate/Private/Capacity.ps1'
    $script:loopPath = Join-Path $script:repoRoot 'Orchestrator/Orchestration/LocalOrchestrator-LoopHelpers.ps1'

    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }
    function Write-OrchestratorLogSafe { param([string]$Message, [string]$Level) }
    function Get-InterclawRepoRoot { return $script:repoRoot }
    function Write-AtomicJson { param([string]$Path, [object]$InputObject) }

    . $script:capacityPath
    . $script:loopPath

    $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "dispatch-prop-test-$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:tempDir -Force
    $script:FileRetryBudgetPath = Join-Path $script:tempDir "file-retry-budget.json"
    $script:RetryBudgetLockPath = Join-Path $script:tempDir "file-retry-budget.lock"
}

AfterAll {
    if ($script:tempDir -and (Test-Path $script:tempDir)) {
        Remove-Item $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe "Dispatch capacity property tests" -Tag "Property", "Dispatch" {

    Context "Capacity never exceeds total cap" {
        It "property: new capacity does not exceed available slots (no zombies)" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(2, 24)
                $reviewerParallel = $rng.Next(1, 12)
                $coderWorkload = $rng.Next(1, 30)
                $reviewerWorkload = $rng.Next(1, 30)
                $activeCoder = $rng.Next(0, [math]::Min($parallelCount - 1, 8))
                $activeReviewer = $rng.Next(0, [math]::Min($reviewerParallel - 1, 4))

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
                    -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer

                $availableSlots = [math]::Max(0, $parallelCount - $activeCoder - $activeReviewer)
                ($cap.CapacityCoder + $cap.CapacityReviewer) | Should -BeLessOrEqual $availableSlots
            } -Seed 400001 -NumRuns 50 -Description "new capacity <= available slots"
            $result.Passed | Should -Be $true
        }
    }

    Context "Role caps respected" {
        It "property: CoderCapacity <= ParallelCount - ActiveCoder" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(1, 24)
                $reviewerParallel = $rng.Next(1, 12)
                $coderWorkload = $rng.Next(1, 30)
                $reviewerWorkload = $rng.Next(1, 30)
                $activeCoder = $rng.Next(0, [math]::Min($parallelCount, 8))

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
                    -ActiveCoder $activeCoder -ActiveReviewer 0

                $cap.CapacityCoder | Should -BeLessOrEqual ($parallelCount - $activeCoder)
            } -Seed 400010 -NumRuns 40 -Description "coder cap respected"
            $result.Passed | Should -Be $true
        }

        It "property: ReviewerCapacity <= ReviewerParallelCount - ActiveReviewer" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(3, 24)
                $reviewerParallel = $rng.Next(1, 12)
                $coderWorkload = $rng.Next(1, 30)
                $reviewerWorkload = $rng.Next(1, 30)
                $activeReviewer = $rng.Next(0, $reviewerParallel)

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
                    -ActiveCoder 0 -ActiveReviewer $activeReviewer

                $cap.CapacityReviewer | Should -BeLessOrEqual ($reviewerParallel - $activeReviewer)
            } -Seed 400020 -NumRuns 40 -Description "reviewer cap respected"
            $result.Passed | Should -Be $true
        }
    }

    Context "Zero workload yields zero capacity" {
        It "property: when both workloads are 0, both capacities are 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(1, 20)
                $reviewerParallel = $rng.Next(1, 10)

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload 0 -ReviewerWorkload 0 `
                    -ActiveCoder 0 -ActiveReviewer 0

                $cap.CapacityCoder | Should -Be 0
                $cap.CapacityReviewer | Should -Be 0
            } -Seed 400030 -NumRuns 20 -Description "zero workload yields zero capacity"
            $result.Passed | Should -Be $true
        }
    }

    Context "Capacities never negative" {
        It "property: no negative capacity for any valid input combination" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(1, 24)
                $reviewerParallel = $rng.Next(1, 12)
                $coderWorkload = $rng.Next(0, 30)
                $reviewerWorkload = $rng.Next(0, 30)
                $activeCoder = $rng.Next(0, [math]::Min($parallelCount, 10))
                $activeReviewer = $rng.Next(0, [math]::Min($reviewerParallel, 5))

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
                    -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer

                $cap.CapacityCoder | Should -BeGreaterOrEqual 0
                $cap.CapacityReviewer | Should -BeGreaterOrEqual 0
            } -Seed 400040 -NumRuns 60 -Description "capacities never negative"
            $result.Passed | Should -Be $true
        }
    }

    Context "Single-role workload" {
        It "property: when only coder has work, reviewer capacity is 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(3, 24)
                $reviewerParallel = $rng.Next(1, 12)
                $activeCoder = $rng.Next(0, 3)
                $activeReviewer = $rng.Next(0, 2)

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload $rng.Next(1, 20) -ReviewerWorkload 0 `
                    -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer

                $cap.CapacityReviewer | Should -Be 0
            } -Seed 400050 -NumRuns 25 -Description "only coder work -> reviewer=0"
            $result.Passed | Should -Be $true
        }

        It "property: when only reviewer has work, coder capacity is 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(3, 24)
                $reviewerParallel = $rng.Next(1, 12)
                $activeCoder = $rng.Next(0, 3)
                $activeReviewer = $rng.Next(0, 2)

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload 0 -ReviewerWorkload $rng.Next(1, 20) `
                    -ActiveCoder $activeCoder -ActiveReviewer $activeReviewer

                $cap.CapacityCoder | Should -Be 0
            } -Seed 400060 -NumRuns 25 -Description "only reviewer work -> coder=0"
            $result.Passed | Should -Be $true
        }
    }

    Context "MaxNewStreamsPerIteration cap" {
        It "property: new capacity capped when no zombies and no active streams" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $parallelCount = $rng.Next(10, 30)
                $reviewerParallel = $rng.Next(5, 15)
                $maxNew = $rng.Next(1, 8)
                $coderWorkload = $rng.Next(10, 50)
                $reviewerWorkload = $rng.Next(10, 50)

                $cap = Get-DynamicCapacity -CodeParallelCount $parallelCount -ReviewerParallelCount $reviewerParallel `
                    -CoderWorkload $coderWorkload -ReviewerWorkload $reviewerWorkload `
                    -ActiveCoder 0 -ActiveReviewer 0 -MaxNewStreamsPerIteration $maxNew

                ($cap.CapacityCoder + $cap.CapacityReviewer) | Should -BeLessOrEqual $maxNew
            } -Seed 400070 -NumRuns 30 -Description "new stream cap respected"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Retry budget property tests" -Tag "Property", "Dispatch" {

    Context "Increment idempotency" {
        It "property: incrementing N times yields retry count = N" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $N = $rng.Next(1, 15)
                $fileName = "retry-inc-$seed.md"

                Reset-FileRetry -FileName $fileName
                for ($i = 0; $i -lt $N; $i++) {
                    $null = Increment-FileRetry -FileName $fileName -StreamId "s1" -ExitCode 1
                }
                $count = Get-FileRetryCount -FileName $fileName
                $count | Should -Be $N
                Reset-FileRetry -FileName $fileName
            } -Seed 400080 -NumRuns 40 -Description "increment N times yields N"
            $result.Passed | Should -Be $true
        }
    }

    Context "Reset clears budget" {
        It "property: reset after increment yields 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $N = $rng.Next(1, 10)
                $fileName = "retry-reset-$seed.md"

                for ($i = 0; $i -lt $N; $i++) {
                    $null = Increment-FileRetry -FileName $fileName -StreamId "s1" -ExitCode 1
                }
                Reset-FileRetry -FileName $fileName
                $count = Get-FileRetryCount -FileName $fileName
                $count | Should -Be 0
            } -Seed 400090 -NumRuns 30 -Description "reset yields 0"
            $result.Passed | Should -Be $true
        }
    }

    Context "Budget threshold" {
        It "property: files below MaxFileRetries do not exceed budget" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $N = $rng.Next(0, $script:MaxFileRetries - 1)
                $fileName = "retry-budget-$seed.md"

                Reset-FileRetry -FileName $fileName
                for ($i = 0; $i -lt $N; $i++) {
                    $null = Increment-FileRetry -FileName $fileName -StreamId "s1" -ExitCode 1
                }
                $exceeded = Test-FileExceededRetryBudget -FileName $fileName
                $exceeded | Should -Be $false
                Reset-FileRetry -FileName $fileName
            } -Seed 400100 -NumRuns 25 -Description "below threshold does not exceed"
            $result.Passed | Should -Be $true
        }

        It "property: files at or above MaxFileRetries do exceed budget" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $N = $rng.Next($script:MaxFileRetries, $script:MaxFileRetries + 5)
                $fileName = "retry-exceed-$seed.md"

                Reset-FileRetry -FileName $fileName
                for ($i = 0; $i -lt $N; $i++) {
                    $null = Increment-FileRetry -FileName $fileName -StreamId "s1" -ExitCode 1
                }
                $exceeded = Test-FileExceededRetryBudget -FileName $fileName
                $exceeded | Should -Be $true
                Reset-FileRetry -FileName $fileName
            } -Seed 400110 -NumRuns 15 -Description "at or above threshold exceeds"
            $result.Passed | Should -Be $true
        }
    }

    Context "Unknown file returns 0" {
        It "property: Get-FileRetryCount returns 0 for unknown files" {
            $result = Invoke-Property {
                param($seed)
                $fileName = "unknown-retry-$seed.md"
                $count = Get-FileRetryCount -FileName $fileName
                $count | Should -Be 0
            } -Seed 400120 -NumRuns 20 -Description "unknown file returns 0"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Stall detection property tests" -Tag "Property", "Dispatch" {

    Context "Reset on progress" {
        It "property: stall count resets when queue shrinks" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $prevCoder = $rng.Next(3, 20)
                $prevReview = $rng.Next(1, 10)
                $prevWorking = $rng.Next(0, 15)
                $currCoder = $prevCoder - $rng.Next(1, $prevCoder)
                $currReview = [math]::Max(0, $prevReview - $rng.Next(0, $prevReview))
                $prev = [PSCustomObject]@{ RootCoder = $prevCoder; Review = $prevReview; Working = $prevWorking }
                $curr = [PSCustomObject]@{ RootCoder = $currCoder; Review = $currReview; Working = $prevWorking }
                $script:activeStreams = @{}

                $result = Invoke-StallDetection -Counts $curr -PreviousCounts $prev -StallCount 2 -MaxStall 3 -Iteration 3
                $result.NewStallCount | Should -Be 0
                $result.Stalled | Should -BeFalse
            } -Seed 400130 -NumRuns 30 -Description "progress resets stall"
            $result.Passed | Should -Be $true
        }
    }

    Context "First call never stalls" {
        It "property: first call with any counts returns zero stall" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $counts = [PSCustomObject]@{
                    RootCoder = $rng.Next(0, 20)
                    Review = $rng.Next(0, 10)
                    Working = $rng.Next(0, 15)
                }
                $script:activeStreams = @{}

                $result = Invoke-StallDetection -Counts $counts -PreviousCounts $null -StallCount 0 -MaxStall 3 -Iteration 1
                $result.NewStallCount | Should -Be 0
                $result.Stalled | Should -BeFalse
            } -Seed 400140 -NumRuns 20 -Description "first call never stalls"
            $result.Passed | Should -Be $true
        }
    }

    Context "Active streams defer stall" {
        It "property: active streams prevent stall detection" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $counts = [PSCustomObject]@{
                    RootCoder = $rng.Next(3, 20)
                    Review = $rng.Next(1, 10)
                    Working = $rng.Next(0, 15)
                }
                $script:activeStreams = @{
                    "ns-$seed" = @{ Process = [PSCustomObject]@{ HasExited = $false } }
                }

                $result = Invoke-StallDetection -Counts $counts -PreviousCounts $counts -StallCount 0 -MaxStall 3 -Iteration 2
                $result.NewStallCount | Should -Be 0
                $result.Stalled | Should -BeFalse
            } -Seed 400150 -NumRuns 20 -Description "active streams defer stall"
            $result.Passed | Should -Be $true
        }
    }
}
