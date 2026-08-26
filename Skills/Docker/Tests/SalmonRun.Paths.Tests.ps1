#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Paths Module FunctionsToExport" -Tag "Paths", "Regression-Only" {
    It "exports the 6 expected functions" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Paths\SalmonRun.Paths.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport
        $exports | Should -Contain "Get-SalmonRunRepoRoot"
        $exports | Should -Contain "Get-HomeDir"
        $exports | Should -Contain "Get-RepoRoot"
        $exports | Should -Contain "Get-SkillsRoot"
        $exports | Should -Contain "Resolve-SkillPath"
        $exports | Should -Contain "Get-SalmonHome"
        $exports | Should -Contain "Get-SalmonTaskRoot"
        $exports | Should -Contain "Reset-SalmonRunPathCache"
        $exports.Count | Should -Be 8
    }

    It "exports the 2 expected aliases" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Paths\SalmonRun.Paths.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.AliasesToExport | Should -Contain "Get-InterclawRepoRoot"
        $manifest.AliasesToExport | Should -Contain "Reset-InterclawPathCache"
    }
}

Describe "Get-SalmonRunRepoRoot" -Tag "Paths" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        . $modulePath
        Reset-SalmonRunPathCache

        $script:SavedPSScriptRoot = $env:PSScriptRoot
        $script:SavedRepoRoot = $env:REPO_ROOT
    }

    AfterAll {
        if ($null -ne $script:SavedPSScriptRoot) { $env:PSScriptRoot = $script:SavedPSScriptRoot } else { Remove-Item Env:\PSScriptRoot -ErrorAction SilentlyContinue }
        if ($null -ne $script:SavedRepoRoot) { $env:REPO_ROOT = $script:SavedRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
        Reset-SalmonRunPathCache
    }

    It "detects repo root by AGENTS.md" {
        Reset-SalmonRunPathCache
        $root = Get-SalmonRunRepoRoot
        $root | Should -Not -BeNullOrEmpty
        (Test-Path (Join-Path $root "AGENTS.md")) | Should -Be $true
    }

    It "honors env:PSScriptRoot override" {
        Reset-SalmonRunPathCache
        $env:PSScriptRoot = $PSScriptRoot
        $root = Get-SalmonRunRepoRoot
        $root | Should -Not -BeNullOrEmpty
        Remove-Item Env:\PSScriptRoot -ErrorAction SilentlyContinue
    }

    It "returns cached root on second call" {
        Reset-SalmonRunPathCache
        $first = Get-SalmonRunRepoRoot
        $second = Get-SalmonRunRepoRoot
        $second | Should -Be $first
    }

    It "falls back to Location when PSScriptRoot is null" {
        Reset-SalmonRunPathCache
        Remove-Item Env:\PSScriptRoot -ErrorAction SilentlyContinue
        $root = Get-SalmonRunRepoRoot
        $root | Should -Not -BeNullOrEmpty
    }

    It "re-resolves after cache reset" {
        Reset-SalmonRunPathCache
        $first = Get-SalmonRunRepoRoot
        Reset-SalmonRunPathCache
        $second = Get-SalmonRunRepoRoot
        $second | Should -Be $first
    }
}

Describe "Get-HomeDir" -Tag "Paths" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        . $modulePath
        Reset-SalmonRunPathCache

        $script:SavedInterclawHome = $env:INTERCLAW_HOME
        $script:SavedUserProfile = $env:USERPROFILE
        $script:HomeIsWritable = $true
        try { $env:HOME = $env:HOME } catch { $script:HomeIsWritable = $false }
    }

    AfterAll {
        if ($null -ne $script:SavedInterclawHome) { $env:INTERCLAW_HOME = $script:SavedInterclawHome } else { Remove-Item Env:\INTERCLAW_HOME -ErrorAction SilentlyContinue }
        if ($null -ne $script:SavedUserProfile) { $env:USERPROFILE = $script:SavedUserProfile } else { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue }
        Reset-SalmonRunPathCache
    }

    It "returns INTERCLAW_HOME when set" {
        Reset-SalmonRunPathCache
        $env:INTERCLAW_HOME = "C:\Custom\Home"
        $homeDir = Get-HomeDir
        $homeDir | Should -Be "C:\Custom\Home"
        Remove-Item Env:\INTERCLAW_HOME -ErrorAction SilentlyContinue
    }

    It "falls back to USERPROFILE when INTERCLAW_HOME is not set" {
        Reset-SalmonRunPathCache
        Remove-Item Env:\INTERCLAW_HOME -ErrorAction SilentlyContinue
        $env:USERPROFILE = "C:\Users\ProfileTest"
        $homeDir = Get-HomeDir
        $homeDir | Should -Be "C:\Users\ProfileTest"
        Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
    }

    It "uses default C:\Users\node as last resort when INTERCLAW_HOME and USERPROFILE are not set" {
        Reset-SalmonRunPathCache
        Remove-Item Env:\INTERCLAW_HOME -ErrorAction SilentlyContinue
        Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
        $default = if ($IsWindows -or $env:OS -eq "Windows_NT") { "C:\Users\node" } else { "/home/node" }
        $homeDir = Get-HomeDir
        $homeDir | Should -Be $default
        $env:USERPROFILE = $script:SavedUserProfile
    }

    It "caches result after first call" {
        Reset-SalmonRunPathCache
        Remove-Item Env:\INTERCLAW_HOME -ErrorAction SilentlyContinue
        $env:USERPROFILE = "C:\Users\CacheTest"
        $first = Get-HomeDir
        $env:USERPROFILE = "C:\Users\Different"
        $second = Get-HomeDir
        $second | Should -Be $first
        Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
    }
}

Describe "Reset-SalmonRunPathCache" -Tag "Paths" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        . $modulePath
        Reset-SalmonRunPathCache
    }

    It "clears both cached values" {
        Reset-SalmonRunPathCache
        $repoRoot = Get-SalmonRunRepoRoot
        $homeDir = Get-HomeDir
        $beforeRepo = $script:CachedRepoRoot
        $beforeHome = $script:CachedHomeDir

        Reset-SalmonRunPathCache

        $script:CachedRepoRoot | Should -Be $null
        $script:CachedHomeDir | Should -Be $null
    }

    It "returns different home dir after reset when env changes" {
        Reset-SalmonRunPathCache
        $env:INTERCLAW_HOME = "C:\First"
        $firstDir = Get-HomeDir
        Reset-SalmonRunPathCache
        $env:INTERCLAW_HOME = "C:\Second"
        $secondDir = Get-HomeDir
        $secondDir | Should -Be "C:\Second"
        $secondDir | Should -Not -Be $firstDir
        Remove-Item Env:\INTERCLAW_HOME -ErrorAction SilentlyContinue
    }

    It "re-resolves repo root after reset" {
        Reset-SalmonRunPathCache
        $first = Get-SalmonRunRepoRoot
        Reset-SalmonRunPathCache
        $second = Get-SalmonRunRepoRoot
        $second | Should -Be $first
    }
}

Describe "Get-RepoRoot (internal helper)" -Tag "Paths" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        . $modulePath
        Reset-SalmonRunPathCache

        $script:SavedRepoRoot = $env:REPO_ROOT
    }

    AfterAll {
        if ($null -ne $script:SavedRepoRoot) { $env:REPO_ROOT = $script:SavedRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
        Reset-SalmonRunPathCache
    }

    It "resolves from default path structure" {
        Reset-SalmonRunPathCache
        $root = Get-RepoRoot
        $root | Should -Not -BeNullOrEmpty
    }

    It "honors env:REPO_ROOT override when .git is not found at default" {
        Reset-SalmonRunPathCache
        $env:REPO_ROOT = "C:\FakeRoot"
        $root = Get-RepoRoot
        $root | Should -Be $env:REPO_ROOT
        Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue
        Reset-SalmonRunPathCache
    }

    It "caches result" {
        Reset-SalmonRunPathCache
        $first = Get-RepoRoot
        $second = Get-RepoRoot
        $second | Should -Be $first
    }
}
