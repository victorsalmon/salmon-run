#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $moduleRoot = if ($env:PONDENGINE_MUTATION_MODULE_ROOT) { $env:PONDENGINE_MUTATION_MODULE_ROOT } else { Join-Path $script:RepoRoot 'Modules' }
    $env:PSModulePath = "$moduleRoot$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $moduleRoot 'SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
}

Describe 'Pond scheduling safety' -Tag 'PondEngine','Regression-Only' {
    It 'enforces global ParallelCount across streams' {
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Code
        $pond.Operators.ParallelCount = 2
        $pond.Operators.MaxNewPerIteration = 9
        $context = [PondContext]::new()
        $context.Streams = [Collections.ArrayList]::new()
        $context.UsedNamespaces = @{}
        1..4 | ForEach-Object { $null = $context.Streams.Add((New-PondStream -Id "s$_" -Branch main -Path $TestDrive)) }
        $groups = 1..6 | ForEach-Object { $g=[PondGroup]::new(); $g.Namespace="n$_"; $g.RepoPath="C:\repo$_"; $g }
        $selected = & (Get-Module SalmonRun.PondEngine) { param($p,$g,$c) Select-PondGroups -Pond $p -Groups $g -Context $c } $pond $groups $context
        @($selected) | Should -HaveCount 2
    }

    It 'selects at most one writer for each underlying repository' {
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Code
        $context = [PondContext]::new()
        $context.Streams = [Collections.ArrayList]::new()
        $context.UsedNamespaces = @{}
        1..4 | ForEach-Object { $null = $context.Streams.Add((New-PondStream -Id "s$_" -Branch main -Path $TestDrive)) }
        $groups = @()
        foreach ($pair in @(@('one','C:\same'),@('two','C:\same'),@('three','C:\other'))) {
            $g=[PondGroup]::new(); $g.Namespace=$pair[0]; $g.RepoPath=$pair[1]; $groups += $g
        }
        $selected = & (Get-Module SalmonRun.PondEngine) { param($p,$g,$c) Select-PondGroups -Pond $p -Groups $g -Context $c } $pond $groups $context
        @($selected | Where-Object RepoPath -eq 'C:\same') | Should -HaveCount 1
    }

    It 'treats a base repository and its worktree as one busy writer resource' {
        $baseRepo = Join-Path $TestDrive 'shared-repo'
        $worktree = Join-Path $TestDrive 'shared-worktree'
        $null = git init -b main $baseRepo
        $null = git -C $baseRepo config user.email 'salmon-run-tests@example.invalid'
        $null = git -C $baseRepo config user.name 'Salmon Run Tests'
        $null = git -C $baseRepo commit --allow-empty -m init
        $null = git -C $baseRepo worktree add -b lane $worktree
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Code
        $context = [PondContext]::new()
        $context.Streams = [Collections.ArrayList]::new()
        $context.UsedNamespaces = @{}
        $context.BusyNamespaces = @{ "repo:$($worktree.ToLowerInvariant())" = $true }
        $null = $context.Streams.Add((New-PondStream -Id 's1' -Branch main -Path $worktree))
        $group = [PondGroup]::new(); $group.Namespace='same-common-dir'; $group.RepoPath=$baseRepo
        $selected = & (Get-Module SalmonRun.PondEngine) { param($p,$g,$c) Select-PondGroups -Pond $p -Groups $g -Context $c } $pond @($group) $context
        @($selected) | Should -HaveCount 0
    }

    It 'recovers dead lanes to their source pond and leaves live lanes untouched' {
        $taskRoot = Join-Path $TestDrive 'recovery/Tasks'
        $working = Join-Path $taskRoot 'Working'
        $deadLane = Join-Path $working 'lane-reviewer-4'
        $liveLane = Join-Path $working 'lane-coder-1'
        foreach ($path in $deadLane,$liveLane,(Join-Path $taskRoot 'Review'),(Join-Path $taskRoot 'Code')) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        '# rejected review' | Set-Content (Join-Path $deadLane 'review.md') -NoNewline
        '99999999' | Set-Content (Join-Path $deadLane '.pid') -NoNewline
        '# active code' | Set-Content (Join-Path $liveLane 'code.md') -NoNewline
        "$PID" | Set-Content (Join-Path $liveLane '.pid') -NoNewline
        @{ generation='dead-generation'; recoveryObservedGeneration='dead-generation'; recoveryObservedAt=(Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o'); processId=99999999; sourcePond='Review'; heartbeatAt=(Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o'); attemptId='dead-attempt' } | ConvertTo-Json | Set-Content (Join-Path $deadLane '.lease.json') -NoNewline
        @{ generation='live-generation'; processId=$PID; sourcePond='Code'; heartbeatAt=(Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o'); attemptId='live-attempt' } | ConvertTo-Json | Set-Content (Join-Path $liveLane '.lease.json') -NoNewline
        (Get-Item $deadLane).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item (Join-Path $deadLane 'review.md')).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item $liveLane).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item (Join-Path $liveLane 'code.md')).LastWriteTime = (Get-Date).AddMinutes(-10)

        $result = & (Get-Module SalmonRun.PondEngine) { param($w,$r) Invoke-PondLaneRecovery -WorkingDir $w -TaskRoot $r -StaleThresholdSeconds 60 } $working $taskRoot
        $result.Rescued | Should -Be 1
        Join-Path $taskRoot 'Review/review.md' | Should -Exist
        $deadLane | Should -Not -Exist
        Join-Path $liveLane 'code.md' | Should -Exist
    }

    It 'provides default capacity for the Investigator pond' {
        $stream = New-PondStream -Id 'investigator-capacity' -Branch main -Path $TestDrive
        @($stream.Lanes.Values | Where-Object Role -eq 'investigator') | Should -HaveCount 1
    }

    It 'treats Investigator as an exclusive repository writer' {
        $pond = [Pond]::new()
        $pond.Name = 'Investigate'
        $pond.Role = 'investigator'
        $pond.Operators = [PondOperators]::new()
        $pond.Operators.ParallelCount = 2
        $pond.Operators.MaxNewPerIteration = 2
        $context = [PondContext]::new()
        $context.Streams = [Collections.ArrayList]::new()
        $context.UsedNamespaces = @{}
        $context.BusyNamespaces = @{}
        1..2 | ForEach-Object { $null = $context.Streams.Add((New-PondStream -Id "i$_" -Branch main -Path $TestDrive -RoleCounts @{ investigator = 1 })) }
        $groups = 1..2 | ForEach-Object { $g=[PondGroup]::new(); $g.Namespace="investigate-$_"; $g.RepoPath='C:\same-repo'; $g }
        $selected = & (Get-Module SalmonRun.PondEngine) { param($p,$g,$c) Select-PondGroups -Pond $p -Groups $g -Context $c } $pond $groups $context
        @($selected) | Should -HaveCount 1
    }

    It 'allocates a lane only from the selected repository stream' {
        $currentsBase = Join-Path $TestDrive 'currents-base'
        $uhBase = Join-Path $TestDrive 'uh-base'
        $currentsWorktree = Join-Path $TestDrive 'currents-worktree'
        $uhWorktree = Join-Path $TestDrive 'uh-worktree'
        foreach ($path in $currentsBase,$uhBase) { $null = git init -b main $path }
        $currents = New-PondStream -Id 'currents-ui' -Branch main -Path $currentsWorktree -RoleCounts @{ coder = 1 }
        $currents | Add-Member BaseRepo $currentsBase -Force
        $uh = New-PondStream -Id 'uh-canary' -Branch main -Path $uhWorktree -RoleCounts @{ coder = 1 }
        $uh | Add-Member BaseRepo $uhBase -Force
        $context = [PondContext]::new()
        $context.Streams = [Collections.ArrayList]::new()
        $null = $context.Streams.Add($currents)
        $null = $context.Streams.Add($uh)
        $pond = Get-SalmonRunPonds | Where-Object Name -eq Code
        $lane = & (Get-Module SalmonRun.PondEngine) { param($p,$c,$r) Get-FreePondLane -Pond $p -Context $c -RepoPath $r } $pond $context $uhBase
        $lane.StreamId | Should -Be 'uh-canary'
    }

    It 'requires a stable lease observation before recovering a dead lane' {
        $taskRoot = Join-Path $TestDrive 'lease-observation/Tasks'
        $lane = Join-Path $taskRoot 'Working/lane-coder-lease-1'
        foreach ($path in $lane,(Join-Path $taskRoot 'Code'),(Join-Path $taskRoot 'Paused')) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        '# claimed plan' | Set-Content (Join-Path $lane 'plan.md') -NoNewline
        @{ generation='generation-1'; processId=99999999; sourcePond='Code'; heartbeatAt=(Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o'); attemptId='attempt-1' } | ConvertTo-Json | Set-Content (Join-Path $lane '.lease.json') -NoNewline
        (Get-Item $lane).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item (Join-Path $lane 'plan.md')).LastWriteTime = (Get-Date).AddMinutes(-10)

        $first = & (Get-Module SalmonRun.PondEngine) { param($w,$r) Invoke-PondLaneRecovery -WorkingDir $w -TaskRoot $r -StaleThresholdSeconds 60 } (Join-Path $taskRoot 'Working') $taskRoot
        $first.Rescued | Should -Be 0
        Join-Path $lane 'plan.md' | Should -Exist
        $lease = Get-Content (Join-Path $lane '.lease.json') -Raw | ConvertFrom-Json
        $lease.recoveryObservedGeneration | Should -Be 'generation-1'
    }

    It 'does not rescue a lane that has a completed result sentinel' {
        $taskRoot = Join-Path $TestDrive 'lease-complete/Tasks'
        $lane = Join-Path $taskRoot 'Working/lane-coder-lease-2'
        foreach ($path in $lane,(Join-Path $taskRoot 'Code'),(Join-Path $taskRoot 'Paused')) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        '# completed plan' | Set-Content (Join-Path $lane 'plan.md') -NoNewline
        '1' | Set-Content (Join-Path $lane '.complete') -NoNewline
        @{ generation='generation-2'; recoveryObservedGeneration='generation-2'; recoveryObservedAt=(Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o'); processId=99999999; sourcePond='Code'; heartbeatAt=(Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o'); attemptId='attempt-2' } | ConvertTo-Json | Set-Content (Join-Path $lane '.lease.json') -NoNewline
        (Get-Item $lane).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item (Join-Path $lane 'plan.md')).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item (Join-Path $lane '.complete')).LastWriteTime = (Get-Date).AddMinutes(-10)
        (Get-Item (Join-Path $lane '.lease.json')).LastWriteTime = (Get-Date).AddMinutes(-10)

        $result = & (Get-Module SalmonRun.PondEngine) { param($w,$r) Invoke-PondLaneRecovery -WorkingDir $w -TaskRoot $r -StaleThresholdSeconds 60 } (Join-Path $taskRoot 'Working') $taskRoot
        $result.Rescued | Should -Be 0
        Join-Path $lane 'plan.md' | Should -Exist
    }

    It 'keeps one gate attempt identity across coordinator claim and child prepare' {
        $taskRoot = Join-Path $TestDrive 'attempt-identity/Tasks'
        $lane = Join-Path $taskRoot 'Working/lane-coder-attempt'
        New-Item $lane -ItemType Directory -Force | Out-Null
        $plan = Join-Path $lane 'plan.md'
        "# Plan`n**Status**: ready`n**Scope**: test" | Set-Content $plan -NoNewline
        $ids = & (Get-Module SalmonRun.PondEngine) { param($p,$t) @((Initialize-PondGateAttempt $p 'Code' $t),(Initialize-PondGateAttempt $p 'Code' $t)) } $plan $taskRoot
        $ids[1].AttemptId | Should -Be $ids[0].AttemptId
        $ids[1].GateAttempt | Should -Be 1
    }

    It 'renews a lease without changing generation or attempt identity' {
        $lane = Join-Path $TestDrive 'lease-heartbeat'
        New-Item $lane -ItemType Directory -Force | Out-Null
        $before = & (Get-Module SalmonRun.PondEngine) { param($l) Write-PondLaneLease $l 'generation' 'Code' 'attempt' 0 } $lane
        Start-Sleep -Milliseconds 25
        $updated = & (Get-Module SalmonRun.PondEngine) { param($l) Update-PondLaneLeaseHeartbeat $l $PID } $lane
        $lease = Get-Content (Join-Path $lane '.lease.json') -Raw | ConvertFrom-Json
        $updated | Should -BeTrue
        $lease.generation | Should -Be 'generation'
        $lease.attemptId | Should -Be 'attempt'
        $lease.processId | Should -Be $PID
        ([datetimeoffset]$lease.heartbeatAt) -ge ([datetimeoffset]$before.heartbeatAt) | Should -BeTrue
    }

    It 'memoizes canonical repository identity for repeated scheduling checks' {
        $repo = Join-Path $TestDrive 'identity-cache-repo'
        New-Item (Join-Path $repo '.git') -ItemType Directory -Force | Out-Null
        & (Get-Module SalmonRun.PondEngine) { $script:PondRepositoryKeyCache = @{} }
        Mock git { $global:LASTEXITCODE = 0; '.git' } -ModuleName SalmonRun.PondEngine

        $keys = & (Get-Module SalmonRun.PondEngine) { param($path) @((Get-PondRepositoryKey $path),(Get-PondRepositoryKey $path)) } $repo

        $keys[1] | Should -Be $keys[0]
        Should -Invoke git -ModuleName SalmonRun.PondEngine -Times 1 -Exactly
    }

    It 'reserves a lane for a stream whose planned worktree does not exist yet' {
        $baseRepo = Join-Path $TestDrive 'bootstrap-base-repo'
        $plannedWorktree = Join-Path $TestDrive 'bootstrap-planned-worktree'
        $taskRoot = Join-Path $TestDrive 'bootstrap-tasks'
        $null = New-Item -ItemType Directory -Path $baseRepo -Force

        $stream = New-PondStream -Id 'bootstrap' -Branch 'salmon-bootstrap' -Path $plannedWorktree -TaskRoot $taskRoot -RoleCounts @{ qa = 1 }
        $stream | Add-Member -NotePropertyName BaseRepo -NotePropertyValue $baseRepo -Force
        $context = [PondContext]::new()
        $context.Streams = [System.Collections.ArrayList]::new()
        $null = $context.Streams.Add($stream)
        $pond = Get-SalmonRunPonds | Where-Object Name -eq 'QA'

        $lane = & (Get-Module SalmonRun.PondEngine) {
            param($p, $c, $repo)
            Get-FreePondLane -Pond $p -Context $c -RepoPath $repo
        } $pond $context $plannedWorktree

        $lane | Should -Not -BeNullOrEmpty
        $lane.StreamId | Should -Be 'bootstrap'
        $plannedWorktree | Should -Not -Exist
    }
}