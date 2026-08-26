#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    $__ModulesDir = Join-Path $__RepoRoot 'Orchestrator' 'Modules'

    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Write-OrchestratorLog { param([string]$Message, [string]$Level) }

    $script:PondEnginePsd1 = Join-Path $__ModulesDir 'SalmonRun.PondEngine' 'SalmonRun.PondEngine.psd1'
    Import-Module $script:PondEnginePsd1 -Force -ErrorAction Stop
}

Describe 'SalmonRun.PondEngine Module Manifest' -Tag 'PondEngine', 'Regression-Only' {
    It 'psd1 exists' {
        Test-Path $script:PondEnginePsd1 | Should -Be $true
    }

    It 'exports the expected functions' {
        $manifest = Import-PowerShellDataFile -Path $script:PondEnginePsd1
        $manifest.FunctionsToExport | Should -Contain 'Get-SalmonRunPonds'
        $manifest.FunctionsToExport | Should -Contain 'Start-PondEngine'
    }
}

Describe 'Get-SalmonRunPonds' -Tag 'PondEngine', 'Regression-Only' {
    It 'returns a non-empty array of Ponds' {
        $ponds = Get-SalmonRunPonds
        $ponds | Should -Not -BeNullOrEmpty
        $ponds.Count | Should -BeGreaterThan 0
        $ponds[0] | Should -BeOfType [Pond]
    }

    It 'includes the expected pond names' {
        $ponds = Get-SalmonRunPonds
        $names = $ponds | ForEach-Object { $_.Name }
        $expected = @('Intake', 'Code', 'Review', 'Audit', 'QA', 'Project', 'ProjectReview', 'Complete')
        foreach ($name in $expected) {
            $names | Should -Contain $name
        }
    }

    It 'gives every pond a folder, role, and capacity' {
        $ponds = Get-SalmonRunPonds
        foreach ($p in $ponds) {
            $p.Folder | Should -Not -BeNullOrEmpty -Because "pond '$($p.Name)' should have a folder"
            $p.Role | Should -Not -BeNullOrEmpty -Because "pond '$($p.Name)' should have a role"
            $p.Capacity | Should -Not -BeNullOrEmpty -Because "pond '$($p.Name)' should have capacity"
            $p.Capacity.ParallelCount | Should -BeGreaterOrEqual 1
        }
    }

    It 'has success transitions between expected ponds' {
        $ponds = Get-SalmonRunPonds | Where-Object { $_.Name -in @('Code', 'Review', 'Audit', 'QA', 'Project', 'ProjectReview') }
        $map = @{}
        foreach ($p in $ponds) { $map[$p.Name] = $p.OnSuccess.MoveTo }

        $map['Code'] | Should -Be 'Review'
        $map['Review'] | Should -Be 'Audit'
        $map['Audit'] | Should -Be 'QA'
        $map['QA'] | Should -Be 'Complete'
        $map['Project'] | Should -Be 'ProjectReview'
        $map['ProjectReview'] | Should -Be 'Complete'
    }
}

Describe 'Pond classes' -Tag 'PondEngine', 'Regression-Only' {
    It 'can construct a PondContext' {
        $c = [PondContext]::new()
        $c | Should -Not -BeNullOrEmpty
    }

    It 'can construct a PondGroup' {
        $g = [PondGroup]::new()
        $g | Should -Not -BeNullOrEmpty
    }
}
