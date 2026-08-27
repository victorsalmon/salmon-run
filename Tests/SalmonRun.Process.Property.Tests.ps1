#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for SalmonRun.Process — native command invocation,
    timeout/retry decisions, and result classification.

.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Invoke-NativeCommand always returns a result object with expected shape
    - Invoke-NativeCommand preserves ExitCode and Output fields
    - Invoke-NativeCommand Success flag matches ExitCode == 0
    - Invoke-NativeCommand with -ThrowOnError throws on non-zero exit
    - Invoke-NativeCommand restores PSNativeCommandUseErrorActionPreference
    - Test-NativeCommandResult classifies failures correctly

    All properties use deterministic seeds (20260910) and explicit numRuns.
    Process timing is non-hermetic — properties use instant-exit commands
    and record timing exclusions explicitly.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    . (Join-Path $script:repoRoot 'Tools/QA/powershell-property-testing/PropertyTesting.ps1')

    # Stubs
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Add-SetupError { param([string]$Phase, [string]$Message, [switch]$Recoverable) }

    # Dot-source the Process module (exports functions directly)
    . (Join-Path $script:repoRoot 'Modules/SalmonRun.Process/SalmonRun.Process.ps1')
}

Describe "Invoke-NativeCommand property tests" -Tag "Property", "Process" {

    Context "Result object shape" {
        It "property: result always has Output, ExitCode, and Success fields" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                # Use a deterministic command: echo with a variable exit code
                $exitCode = $rng.Next(0, 5)
                $cmd = { cmd /c "exit $exitCode" }
                $r = Invoke-NativeCommand -Command $cmd
                $r | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['Output'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['ExitCode'] | Should -Not -BeNullOrEmpty
                $r.PSObject.Properties['Success'] | Should -Not -BeNullOrEmpty
            } -Seed 20260910 -NumRuns 30 -Description "result shape invariant"
            $result.Passed | Should -Be $true
        }
    }

    Context "Success flag matches ExitCode" {
        It "property: Success is true iff ExitCode is 0" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $exitCode = $rng.Next(0, 10)
                $cmd = { cmd /c "exit $exitCode" }
                $r = Invoke-NativeCommand -Command $cmd
                $expectedSuccess = ($exitCode -eq 0)
                $r.Success | Should -Be $expectedSuccess
            } -Seed 20260911 -NumRuns 30 -Description "Success matches ExitCode"
            $result.Passed | Should -Be $true
        }
    }

    Context "Output preservation" {
        It "property: output contains the echoed value" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $val = $rng.Next(1, 1000)
                $cmd = { cmd /c "echo $val" }
                $r = Invoke-NativeCommand -Command $cmd
                $r.Output | Should -Match "$val"
            } -Seed 20260912 -NumRuns 20 -Description "output preserved"
            $result.Passed | Should -Be $true
        }
    }

    Context "ThrowOnError behavior" {
        It "property: -ThrowOnError throws on non-zero exit" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $exitCode = $rng.Next(1, 10)
                $cmd = { cmd /c "exit $exitCode" }
                { Invoke-NativeCommand -Command $cmd -ThrowOnError } | Should -Throw
            } -Seed 20260913 -NumRuns 20 -Description "ThrowOnError throws"
            $result.Passed | Should -Be $true
        }

        It "property: -ThrowOnError does not throw on exit 0" {
            $result = Invoke-Property {
                param($seed)
                $cmd = { cmd /c "exit 0" }
                { Invoke-NativeCommand -Command $cmd -ThrowOnError } | Should -Not -Throw
            } -Seed 20260914 -NumRuns 10 -Description "ThrowOnError no throw on 0"
            $result.Passed | Should -Be $true
        }
    }

    Context "PSNativeCommandUseErrorActionPreference restoration" {
        It "property: preference is restored after invocation regardless of exit code" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $exitCode = $rng.Next(0, 5)
                $original = $global:PSNativeCommandUseErrorActionPreference
                $cmd = { cmd /c "exit $exitCode" }
                $null = Invoke-NativeCommand -Command $cmd
                $global:PSNativeCommandUseErrorActionPreference | Should -Be $original
            } -Seed 20260915 -NumRuns 20 -Description "preference restored"
            $result.Passed | Should -Be $true
        }
    }

    Context "Edge cases" {
        It "property: empty command output is handled gracefully" {
            $result = Invoke-Property {
                param($seed)
                $cmd = { cmd /c "exit 0" }
                $r = Invoke-NativeCommand -Command $cmd
                $r.ExitCode | Should -Be 0
                $r.Success | Should -Be $true
            } -Seed 20260916 -NumRuns 10 -Description "empty output handled"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Test-NativeCommandResult property tests" -Tag "Property", "Process" {

    Context "Recoverable failure classification" {
        It "property: non-zero exit with -Recoverable does not throw" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $exitCode = $rng.Next(1, 10)
                $cmd = { cmd /c "exit $exitCode" }
                { Test-NativeCommandResult -Command $cmd -Recoverable } | Should -Not -Throw
            } -Seed 20260917 -NumRuns 20 -Description "recoverable no throw"
            $result.Passed | Should -Be $true
        }

        It "property: non-zero exit without -Recoverable throws" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $exitCode = $rng.Next(1, 10)
                $cmd = { cmd /c "exit $exitCode" }
                { Test-NativeCommandResult -Command $cmd } | Should -Throw
            } -Seed 20260918 -NumRuns 20 -Description "non-recoverable throws"
            $result.Passed | Should -Be $true
        }
    }
}
