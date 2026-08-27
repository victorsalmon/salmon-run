#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for SalmonRun.Constants — registry round trips,
    boundary strings, unknown keys, and port-registry consistency.

.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Constants hashtable round-trip (every key has a non-null value)
    - Port constants match port-registry entries (where active)
    - Network name keys are ordered and unique
    - Boundary string inputs to Get-DefaultRegion and Get-ProjectCode
    - Unknown key lookups return safe defaults

    All properties use deterministic seeds and explicit numRuns.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.FullName
    . (Join-Path $script:repoRoot 'Skills/QA/powershell-property-testing/PropertyTesting.ps1')

    $script:orchModulesDir = Join-Path $script:repoRoot "Orchestrator" "Modules"
    $script:dockerModulesDir = Join-Path $script:repoRoot "Skills" "Docker" "Modules"

    # Stubs
    function Get-SalmonRunRepoRoot { return $script:repoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Read-InstallJson { return $null }

    # Load dependency chain
    . (Join-Path $script:dockerModulesDir "SalmonRun.Paths" "SalmonRun.Paths.ps1")
    . (Join-Path $script:dockerModulesDir "SalmonRun.Ports" "SalmonRun.Ports.ps1")
    . (Join-Path $script:dockerModulesDir "SalmonRun.Diagnostics" "SalmonRun.Diagnostics.ps1")
    . (Join-Path $script:orchModulesDir "SalmonRun.Constants" "SalmonRun.Constants.ps1")

    $script:portRegistry = Get-Content -Raw (Join-Path $script:repoRoot "port-registry.json") | ConvertFrom-Json
}

Describe "Get-SalmonRunConstants property tests" -Tag "Property", "Constants" {

    Context "Constants hashtable round-trip" {
        It "property: every key has a non-null, non-empty value" {
            $result = Invoke-Property {
                param($seed)
                $c = Get-SalmonRunConstants
                $c | Should -BeOfType [hashtable]
                foreach ($key in $c.Keys) {
                    $c[$key] | Should -Not -BeNullOrEmpty -Because "key '$key' must have a value"
                }
            } -Seed 20260830 -NumRuns 20 -Description "constants round-trip"
            $result.Passed | Should -Be $true
        }

        It "property: numerical constants are positive integers" {
            $result = Invoke-Property {
                param($seed)
                $c = Get-SalmonRunConstants
                $numericalKeys = @(
                    'GatewayPortBase', 'GatewayPortMultiplier',
                    'AwsKeyPropagationDelaySec', 'AwsKeyPropagationRetries',
                    'HealthCheckMaxRetries', 'HealthCheckRetryIntervalSec',
                    'StackCleanupTimeoutSec', 'StackCleanupRetryIntervalSec',
                    'MaxAgents', 'LogTailLines', 'VolumeSeedRetryMs'
                )
                foreach ($key in $numericalKeys) {
                    $c[$key] | Should -BeOfType [int] -Because "'$key' should be int"
                    $c[$key] | Should -BeGreaterThan 0 -Because "'$key' should be positive"
                }
            } -Seed 20260831 -NumRuns 20 -Description "numerical constants positive"
            $result.Passed | Should -Be $true
        }

        It "property: image constants contain a tag separator" {
            $result = Invoke-Property {
                param($seed)
                $c = Get-SalmonRunConstants
                $imageKeys = @('InterclawImage', 'SentryImage', 'ProxyImage', 'McpBrowserlessImage')
                foreach ($key in $imageKeys) {
                    $c[$key] | Should -BeOfType [string] -Because "'$key' should be string"
                    $c[$key] | Should -Match ':\w+$' -Because "'$key' should end with :tag"
                }
            } -Seed 20260901 -NumRuns 20 -Description "image constants tagged"
            $result.Passed | Should -Be $true
        }
    }

    Context "Port constants match port-registry" {
        It "property: FleetApiPort matches registry internal.is-fleet" {
            $result = Invoke-Property {
                param($seed)
                $c = Get-SalmonRunConstants
                $expected = $script:portRegistry.internal.'is-fleet'
                $c.FleetApiPort | Should -Be $expected
            } -Seed 20260902 -NumRuns 10 -Description "FleetApiPort matches registry"
            $result.Passed | Should -Be $true
        }

        It "property: no port constant falls in retired range" {
            $result = Invoke-Property {
                param($seed)
                $c = Get-SalmonRunConstants
                $retiredPorts = $script:portRegistry.retired.PSObject.Properties.Name
                $portKeys = @('FleetApiPort', 'FleetRotationPort')
                foreach ($key in $portKeys) {
                    if ($c.ContainsKey($key)) {
                        "$($c[$key])" | Should -Not -BeIn $retiredPorts -Because "'$key' should not use a retired port"
                    }
                }
            } -Seed 20260904 -NumRuns 10 -Description "no retired port overlap"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-NetworkNames property tests" -Tag "Property", "Constants" {

    Context "Network name ordering and uniqueness" {
        It "property: keys are in expected order (ServiceNet, OrchestrationNet, ManagementNet, FunnelNet)" {
            $result = Invoke-Property {
                param($seed)
                $n = Get-NetworkNames
                $expected = @('ServiceNet', 'OrchestrationNet', 'ManagementNet', 'FunnelNet')
                $actual = @($n.Keys)
                $actual.Count | Should -Be $expected.Count
                for ($i = 0; $i -lt $expected.Count; $i++) {
                    $actual[$i] | Should -Be $expected[$i]
                }
            } -Seed 20260905 -NumRuns 20 -Description "network key order"
            $result.Passed | Should -Be $true
        }

        It "property: values are non-empty strings" {
            $result = Invoke-Property {
                param($seed)
                $n = Get-NetworkNames
                foreach ($key in $n.Keys) {
                    $n[$key] | Should -BeOfType [string]
                    $n[$key] | Should -Not -BeNullOrEmpty
                }
            } -Seed 20260906 -NumRuns 20 -Description "network values non-empty"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-DefaultRegion boundary inputs" -Tag "Property", "Constants" {

    Context "Boundary string handling" {
        It "property: env var set to boundary value is returned as-is" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("us-east-1", "ca-central-1", "eu-west-1", "ap-southeast-1")
                $region = $boundaries[$rng.Next($boundaries.Count)]
                $saved = $env:AWS_SECRETS_REGION
                try {
                    $env:AWS_SECRETS_REGION = $region
                    Get-DefaultRegion -RegionType AWS_SECRETS_REGION | Should -Be $region
                } finally {
                    $env:AWS_SECRETS_REGION = $saved
                }
            } -Seed 20260907 -NumRuns 30 -Description "boundary region passthrough"
            $result.Passed | Should -Be $true
        }

        It "property: empty env var falls back to hardcoded default" {
            $result = Invoke-Property {
                param($seed)
                $saved = $env:AWS_SECRETS_REGION
                try {
                    Remove-Item Env:\AWS_SECRETS_REGION -ErrorAction SilentlyContinue
                    Get-DefaultRegion -RegionType AWS_SECRETS_REGION | Should -Be "ca-central-1"
                } finally {
                    if ($saved) { $env:AWS_SECRETS_REGION = $saved }
                }
            } -Seed 20260908 -NumRuns 20 -Description "empty env fallback"
            $result.Passed | Should -Be $true
        }

        It "property: invalid RegionType throws" {
            $result = Invoke-Property {
                param($seed)
                { Get-DefaultRegion -RegionType "INVALID" } | Should -Throw
            } -Seed 20260909 -NumRuns 10 -Description "invalid RegionType throws"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-ProjectCode boundary inputs" -Tag "Property", "Constants" {

    Context "Boundary string handling" {
        It "property: non-whitespace INSTALL_PROJECT is returned" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("TEST", "A", "FRAD-2026", "project_with_underscores")
                $code = $boundaries[$rng.Next($boundaries.Count)]
                $saved = $env:INSTALL_PROJECT
                try {
                    $env:INSTALL_PROJECT = $code
                    Get-ProjectCode | Should -Be $code
                } finally {
                    $env:INSTALL_PROJECT = $saved
                }
            } -Seed 20260910 -NumRuns 20 -Description "valid project code"
            $result.Passed | Should -Be $true
        }

        It "property: empty/whitespace INSTALL_PROJECT throws" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $badValues = @("", "   ", "`t", "`n")
                $bad = $badValues[$rng.Next($badValues.Count)]
                $saved = $env:INSTALL_PROJECT
                try {
                    $env:INSTALL_PROJECT = $bad
                    { Get-ProjectCode } | Should -Throw "*INSTALL_PROJECT*"
                } finally {
                    $env:INSTALL_PROJECT = $saved
                }
            } -Seed 20260911 -NumRuns 20 -Description "empty project throws"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-CodingKeyPriority invariants" -Tag "Property", "Constants" {

    Context "Priority list properties" {
        It "property: returns exactly 2 elements" {
            $result = Invoke-Property {
                param($seed)
                $p = Get-CodingKeyPriority
                $p.Count | Should -Be 2
            } -Seed 20260912 -NumRuns 20 -Description "priority count 2"
            $result.Passed | Should -Be $true
        }

        It "property: first key is OPENCODE_GO1_KEY" {
            $result = Invoke-Property {
                param($seed)
                $p = Get-CodingKeyPriority
                $p[0] | Should -Be "OPENCODE_GO1_KEY"
            } -Seed 20260913 -NumRuns 20 -Description "first key"
            $result.Passed | Should -Be $true
        }
    }
}
