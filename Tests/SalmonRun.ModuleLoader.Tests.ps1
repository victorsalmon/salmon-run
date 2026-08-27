#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__modulesDir = [System.IO.Path]::Combine($__repoRoot, "Modules")

    function Get-InterclawRepoRoot { return $__repoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }

    $script:ModuleLoaderPsd1 = [System.IO.Path]::Combine($__modulesDir, "SalmonRun.ModuleLoader", "SalmonRun.ModuleLoader.psd1")
    $script:ModuleLoaderDir = Join-Path $__modulesDir "SalmonRun.ModuleLoader"
}

Describe "SalmonRun.ModuleLoader Module Manifest" -Tag "ModuleLoader", "Regression-Only" {

    It "psd1 file exists" {
        Test-Path $script:ModuleLoaderPsd1 | Should -Be $true
    }

    It "exports exactly 2 functions" {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleLoaderPsd1
        $manifest.FunctionsToExport.Count | Should -Be 2
        $manifest.FunctionsToExport | Should -Contain "Import-InterclawModule"
        $manifest.FunctionsToExport | Should -Contain "Initialize-InterclawEnvironment"
    }

    It "has a valid GUID" {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleLoaderPsd1
        { [guid]::Parse($manifest.GUID) } | Should -Not -Throw
    }

    It "has no RequiredModules" {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleLoaderPsd1
        $manifest.RequiredModules | Should -BeNullOrEmpty
    }
}

Describe "Import-InterclawModule" -Tag "ModuleLoader", "Regression-Only" {

    It "can be dot-sourced without error" {
        { . (Join-Path $script:ModuleLoaderDir "Public\Import-InterclawModule.ps1") } | Should -Not -Throw
    }

    It "defines the Import-InterclawModule function after sourcing" {
        . (Join-Path $script:ModuleLoaderDir "Public\Import-InterclawModule.ps1")
        Get-Command Import-InterclawModule -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "accepts -Name parameter" {
        . (Join-Path $script:ModuleLoaderDir "Public\Import-InterclawModule.ps1")
        $cmd = Get-Command Import-InterclawModule
        $cmd.Parameters.ContainsKey('Name') | Should -Be $true
        ($cmd.Parameters['Name'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
    }

    It "has the proper module path construction logic" {
        . (Join-Path $script:ModuleLoaderDir "Public\Import-InterclawModule.ps1")
        $cmd = Get-Command Import-InterclawModule
        $cmd.ScriptBlock.ToString() | Should -Match 'Interclaw\.\$Name'
        $cmd.ScriptBlock.ToString() | Should -Match "Get-InterclawRepoRoot"
    }
}

Describe "Initialize-InterclawEnvironment" -Tag "ModuleLoader", "Regression-Only" {

    It "can be dot-sourced without error" {
        { . (Join-Path $script:ModuleLoaderDir "Public\Initialize-InterclawEnvironment.ps1") } | Should -Not -Throw
    }

    It "defines the Initialize-InterclawEnvironment function after sourcing" {
        . (Join-Path $script:ModuleLoaderDir "Public\Initialize-InterclawEnvironment.ps1")
        Get-Command Initialize-InterclawEnvironment -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "accepts -RepoRoot parameter" {
        . (Join-Path $script:ModuleLoaderDir "Public\Initialize-InterclawEnvironment.ps1")
        $cmd = Get-Command Initialize-InterclawEnvironment
        $cmd.Parameters.ContainsKey('RepoRoot') | Should -Be $true
    }

    It "returns repo root when called with -RepoRoot" {
        . (Join-Path $script:ModuleLoaderDir "Public\Initialize-InterclawEnvironment.ps1")
        $result = Initialize-InterclawEnvironment -RepoRoot $__repoRoot
        $result | Should -Be $__repoRoot
    }

    It "sets PSModulePath to include Modules dir" {
        . (Join-Path $script:ModuleLoaderDir "Public\Initialize-InterclawEnvironment.ps1")
        $savedPath = $env:PSModulePath
        try {
            $env:PSModulePath = ""
            Initialize-InterclawEnvironment -RepoRoot $__repoRoot
            $env:PSModulePath | Should -Match "Modules"
        } finally {
            $env:PSModulePath = $savedPath
        }
    }
}

Describe "Import-InterclawModule accessible via canonical module" -Tag "ModuleLoader", "Regression-Only" {

    It "is exported by SalmonRun.ModuleLoader manifest" {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleLoaderPsd1
        $manifest.FunctionsToExport | Should -Contain "Import-InterclawModule"
    }

    It "Initialize-InterclawEnvironment is exported by SalmonRun.ModuleLoader manifest" {
        $manifest = Import-PowerShellDataFile -Path $script:ModuleLoaderPsd1
        $manifest.FunctionsToExport | Should -Contain "Initialize-InterclawEnvironment"
    }
}
