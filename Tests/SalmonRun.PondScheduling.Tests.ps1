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
}
