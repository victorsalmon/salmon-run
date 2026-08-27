#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $__modulesDir = [System.IO.Path]::Combine($__repoRoot, "Skills", "Docker", "Modules")

    function Get-InterclawRepoRoot { return $__repoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }

    $script:ResModuleDir = Join-Path $__modulesDir "SalmonRun.Resources"
    $script:ResPsd1 = Join-Path $script:ResModuleDir "SalmonRun.Resources.psd1"
    $script:ResPublic = Join-Path $script:ResModuleDir "Public"

    # Dot-source both Public files
    Get-ChildItem -Path $script:ResPublic -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }
}

Describe "SalmonRun.Resources Module Manifest" -Tag "Resources", "Regression-Only" {

    It "psd1 file exists" {
        Test-Path $script:ResPsd1 | Should -Be $true
    }

    It "exports exactly 2 functions" {
        $manifest = Import-PowerShellDataFile -Path $script:ResPsd1
        $manifest.FunctionsToExport.Count | Should -Be 2
        $manifest.FunctionsToExport | Should -Contain "Measure-DockerResources"
        $manifest.FunctionsToExport | Should -Contain "Test-ResourceBudget"
    }

    It "has a valid GUID" {
        $manifest = Import-PowerShellDataFile -Path $script:ResPsd1
        { [guid]::Parse($manifest.GUID) } | Should -Not -Throw
    }
}

Describe "Measure-DockerResources" -Tag "Resources" {

    It "can be dot-sourced without error" {
        . (Join-Path $script:ResPublic "Measure-DockerResources.ps1")
        { Get-Command Measure-DockerResources -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }

    It "accepts parameters" {
        . (Join-Path $script:ResPublic "Measure-DockerResources.ps1")
        $cmd = Get-Command Measure-DockerResources
        $cmd.Parameters.ContainsKey('AgentCount') | Should -Be $true
        $cmd.Parameters.ContainsKey('IncludeDiskCheck') | Should -Be $true
    }

    It "returns a PSCustomObject with TotalGB, AvailableGB, AvailableDiskGB" {
        . (Join-Path $script:ResPublic "Measure-DockerResources.ps1")
        $result = Measure-DockerResources -AgentCount 1
        $result | Should -BeOfType [pscustomobject]
        $result | Should -HaveProperty TotalGB
        $result | Should -HaveProperty AvailableGB
        $result | Should -HaveProperty AvailableDiskGB
    }

    It "uses DOCKER_INFO_MEMTOTAL_CACHE env var when set" {
        $saved = $env:DOCKER_INFO_MEMTOTAL_CACHE
        try {
            $env:DOCKER_INFO_MEMTOTAL_CACHE = (16GB).ToString()
            $result = Measure-DockerResources -AgentCount 1
            $result.TotalGB | Should -BeGreaterOrEqual 16
        } finally {
            $env:DOCKER_INFO_MEMTOTAL_CACHE = $saved
        }
    }
}

Describe "Test-ResourceBudget" -Tag "Resources" {

    It "can be dot-sourced without error" {
        . (Join-Path $script:ResPublic "Test-ResourceBudget.ps1")
        { Get-Command Test-ResourceBudget -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }

    It "throws when disk is insufficient" {
        . (Join-Path $script:ResPublic "Test-ResourceBudget.ps1")
        { Test-ResourceBudget -AgentCount 100 -IncludeDiskCheck } | Should -Throw
    }
}

Describe "Resources functions accessible via canonical module" -Tag "Resources", "Regression-Only" {

    It "both function names appear in SalmonRun.Resources FunctionsToExport" {
        $manifest = Import-PowerShellDataFile -Path $script:ResPsd1
        $manifest.FunctionsToExport | Should -Contain "Measure-DockerResources"
        $manifest.FunctionsToExport | Should -Contain "Test-ResourceBudget"
    }
}
