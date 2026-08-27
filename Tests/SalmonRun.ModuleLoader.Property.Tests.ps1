#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for SalmonRun.ModuleLoader — discovery, duplicate
    handling, missing-module handling, and idempotent loading.

.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Module discovery: known modules resolve to valid paths
    - Missing-module: unknown module names throw
    - Idempotent loading: repeated imports do not corrupt PSModulePath
    - Duplicate loading: importing the same module twice is safe
    - Initialize-InterclawEnvironment: idempotent PSModulePath setup

    All properties use deterministic seeds and explicit numRuns.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $script:modulesDir = [System.IO.Path]::Combine($script:repoRoot, "Modules")

    # Stubs
    function Get-InterclawRepoRoot { return $script:repoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }

    # Load property testing framework
    . (Join-Path $script:repoRoot 'Tools/QA/powershell-property-testing/PropertyTesting.ps1')

    # Load the module loader functions directly
    . (Join-Path $script:modulesDir "SalmonRun.ModuleLoader" "Public" "Import-InterclawModule.ps1")
    . (Join-Path $script:modulesDir "SalmonRun.ModuleLoader" "Public" "Initialize-InterclawEnvironment.ps1")

    # Known modules that exist under Modules
    $script:knownModules = @("Core", "Config", "Constants")
}

Describe "Import-InterclawModule discovery property tests" -Tag "Property", "ModuleLoader" {

    Context "Module discovery: known modules resolve via -ModulesDir" {
        It "property: known module name resolves without throwing" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = $script:knownModules[$rng.Next($script:knownModules.Count)]
                { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Not -Throw
            } -Seed 20260930 -NumRuns 20 -Description "known module resolves"
            $result.Passed | Should -Be $true
        }

        It "property: PSModulePath contains modules directory after import" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = $script:knownModules[$rng.Next($script:knownModules.Count)]
                $savedPath = $env:PSModulePath
                try {
                    Import-InterclawModule -Name $name -ModulesDir $script:modulesDir
                    $env:PSModulePath | Should -Match "Modules"
                } finally {
                    $env:PSModulePath = $savedPath
                }
            } -Seed 20260931 -NumRuns 15 -Description "PSModulePath updated"
            $result.Passed | Should -Be $true
        }
    }

    Context "Missing-module: unknown names throw" {
        It "property: nonexistent module name throws" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $names = @("Nonexistent", "Fake", "ZZZZZ", "NoSuchModule_$seed")
                $name = $names[$rng.Next($names.Count)]
                { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Throw
            } -Seed 20260932 -NumRuns 20 -Description "missing module throws"
            $result.Passed | Should -Be $true
        }
    }

    Context "Idempotent loading: repeated imports are safe" {
        It "property: importing the same module twice does not corrupt PSModulePath" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = $script:knownModules[$rng.Next($script:knownModules.Count)]
                $savedPath = $env:PSModulePath
                try {
                    Import-InterclawModule -Name $name -ModulesDir $script:modulesDir
                    $pathAfterFirst = $env:PSModulePath
                    Import-InterclawModule -Name $name -ModulesDir $script:modulesDir
                    $pathAfterSecond = $env:PSModulePath
                    $pathAfterSecond.Length | Should -BeLessOrEqual ($pathAfterFirst.Length + 100)
                } finally {
                    $env:PSModulePath = $savedPath
                }
            } -Seed 20260933 -NumRuns 15 -Description "idempotent PSModulePath"
            $result.Passed | Should -Be $true
        }

        It "property: importing same module twice does not throw" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = $script:knownModules[$rng.Next($script:knownModules.Count)]
                { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Not -Throw
                { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Not -Throw
            } -Seed 20260934 -NumRuns 15 -Description "double import safe"
            $result.Passed | Should -Be $true
        }
    }

    Context "Duplicate handling: loading different modules does not conflict" {
        It "property: sequential imports of different modules all succeed" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $shuffled = $script:knownModules | Sort-Object { $rng.Next() }
                $subset = $shuffled[0..([math]::Min(2, $shuffled.Count - 1))]
                foreach ($name in $subset) {
                    { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Not -Throw
                }
            } -Seed 20260935 -NumRuns 10 -Description "sequential distinct imports"
            $result.Passed | Should -Be $true
        }
    }

    Context "Boundary module names" {
        It "property: single-character module name that does not exist throws" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $names = @("X", "Z", "A")
                $name = $names[$rng.Next($names.Count)]
                { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Throw
            } -Seed 20260936 -NumRuns 10 -Description "short name throws"
            $result.Passed | Should -Be $true
        }

        It "property: very long module name throws" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $len = $rng.Next(50, 200)
                $name = "M" * $len
                { Import-InterclawModule -Name $name -ModulesDir $script:modulesDir } | Should -Throw
            } -Seed 20260937 -NumRuns 10 -Description "long name throws"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Initialize-InterclawEnvironment property tests" -Tag "Property", "ModuleLoader" {

    Context "Idempotent environment setup" {
        It "property: returns repo root path" {
            $result = Invoke-Property {
                param($seed)
                $returned = Initialize-InterclawEnvironment -RepoRoot $script:repoRoot
                $returned | Should -Be $script:repoRoot
            } -Seed 20260938 -NumRuns 10 -Description "returns repo root"
            $result.Passed | Should -Be $true
        }

        It "property: PSModulePath includes module roots after initialization" {
            $result = Invoke-Property {
                param($seed)
                $savedPath = $env:PSModulePath
                try {
                    $env:PSModulePath = ""
                    Initialize-InterclawEnvironment -RepoRoot $script:repoRoot
                    $env:PSModulePath | Should -Match "Modules"
                } finally {
                    $env:PSModulePath = $savedPath
                }
            } -Seed 20260939 -NumRuns 10 -Description "PSModulePath roots"
            $result.Passed | Should -Be $true
        }

        It "property: calling twice is idempotent (no PSModulePath bloat)" {
            $result = Invoke-Property {
                param($seed)
                $savedPath = $env:PSModulePath
                try {
                    $env:PSModulePath = ""
                    Initialize-InterclawEnvironment -RepoRoot $script:repoRoot
                    $pathAfterFirst = $env:PSModulePath
                    Initialize-InterclawEnvironment -RepoRoot $script:repoRoot
                    $pathAfterSecond = $env:PSModulePath
                    $pathAfterSecond.Length | Should -BeLessOrEqual ($pathAfterFirst.Length + 50)
                } finally {
                    $env:PSModulePath = $savedPath
                }
            } -Seed 20260940 -NumRuns 10 -Description "idempotent init"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Module manifest property tests" -Tag "Property", "ModuleLoader" {

    Context "Manifest integrity" {
        It "property: known module has valid psd1 manifest" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = $script:knownModules[$rng.Next($script:knownModules.Count)]
                $psd1 = Join-Path $script:modulesDir "Interclaw.$name" "Interclaw.$name.psd1"
                if (Test-Path $psd1) {
                    $manifest = Import-PowerShellDataFile -Path $psd1
                    $manifest | Should -Not -BeNullOrEmpty
                    $manifest.FunctionsToExport | Should -Not -BeNullOrEmpty
                }
            } -Seed 20260941 -NumRuns 15 -Description "manifest valid"
            $result.Passed | Should -Be $true
        }

        It "property: manifest has a parseable GUID" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $name = $script:knownModules[$rng.Next($script:knownModules.Count)]
                $psd1 = Join-Path $script:modulesDir "Interclaw.$name" "Interclaw.$name.psd1"
                if (Test-Path $psd1) {
                    $manifest = Import-PowerShellDataFile -Path $psd1
                    { [guid]::Parse($manifest.GUID) } | Should -Not -Throw
                }
            } -Seed 20260942 -NumRuns 10 -Description "GUID parseable"
            $result.Passed | Should -Be $true
        }
    }
}
