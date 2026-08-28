#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $env:PSModulePath = "$(Join-Path $script:RepoRoot 'Modules')$([IO.Path]::PathSeparator)$env:PSModulePath"
    Remove-Module SalmonRun.PondEngine -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'Modules/SalmonRun.PondEngine/SalmonRun.PondEngine.psd1') -Force
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
}

