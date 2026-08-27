#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Property-based tests for SalmonRun.Config — config normalization,
    default precedence, placeholder resolution, and invalid-input fail-closed.

.DESCRIPTION
    Uses the PowerShell property testing framework to verify invariants over
    generated inputs for:
    - Get-ConfigValue precedence chain (env > alias > install.json > default)
    - Resolve-StringPlaceholders idempotency and boundary strings
    - Update-InstallJsonKey round-trip for various value types
    - Read-InstallJson returns null for invalid/malformed JSON
    - Get-SilentToggle precedence (env > install.json > default)

    All properties use deterministic seeds and explicit numRuns.
#>

BeforeAll {
    $script:repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    . (Join-Path $script:repoRoot 'Tools/QA/powershell-property-testing/PropertyTesting.ps1')

    $script:salmonModules = Join-Path $script:repoRoot 'Modules'
    $script:dockerModules = Join-Path $script:repoRoot 'Modules'

    # Stubs
    function Write-SetupLog { param([string]$Message, [string]$Level) }
    function Invoke-NativeCommand { param($Command) return [pscustomobject]@{ Success = $false } }

    # Load dependency chain
    . (Join-Path $script:salmonModules "SalmonRun.Core" "SalmonRun.Core.ps1")
    . (Join-Path $script:salmonModules "SalmonRun.Config" "SalmonRun.Config.ps1")
}

Describe "Get-ConfigValue property tests" -Tag "Property", "Config" {

    Context "Precedence chain: env > alias > install.json > default" {
        BeforeEach {
            $script:TestJsonFile = Join-Path $env:TEMP "prop-test-config-$(Get-Random).json"
            '{"project": {"code": "from_json"}, "features": {"sentry": {"install": true}}}' | Set-Content $script:TestJsonFile
            $env:ORCHESTRATOR_INSTALL_JSON = $script:TestJsonFile
        }

        AfterEach {
            if (Test-Path $script:TestJsonFile) { Remove-Item $script:TestJsonFile }
            Remove-Item Env:\ORCHESTRATOR_INSTALL_JSON -ErrorAction SilentlyContinue
            Remove-Item Env:\PROP_TEST_VAR -ErrorAction SilentlyContinue
            Remove-Item Env:\PROP_TEST_ALIAS -ErrorAction SilentlyContinue
        }

        It "property: env var wins over install.json" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("from_env_1", "from_env_2", "TESTCODE")
                $val = $boundaries[$rng.Next($boundaries.Count)]
                $env:PROP_TEST_VAR = $val
                Get-ConfigValue -VarName "PROP_TEST_VAR" -NonInteractive | Should -Be $val
            } -Seed 20260914 -NumRuns 30 -Description "env beats json"
            $result.Passed | Should -Be $true
        }

        It "property: alias env var is resolved when primary is missing" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("alias_val_1", "alias_val_2", "ALIAS_TEST")
                $val = $boundaries[$rng.Next($boundaries.Count)]
                Remove-Item Env:\PROP_TEST_VAR -ErrorAction SilentlyContinue
                $env:PROP_TEST_ALIAS = $val
                $resolved = Get-ConfigValue -VarName "PROP_TEST_VAR" -Aliases @("PROP_TEST_ALIAS") -NonInteractive
                $resolved | Should -Be $val
            } -Seed 20260915 -NumRuns 30 -Description "alias resolution"
            $result.Passed | Should -Be $true
        }

        It "property: default is used when no env and no json match" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("fallback", "DEFAULT_1", "d")
                $def = $boundaries[$rng.Next($boundaries.Count)]
                Remove-Item Env:\PROP_TEST_VAR -ErrorAction SilentlyContinue
                Remove-Item Env:\PROP_TEST_ALIAS -ErrorAction SilentlyContinue
                Get-ConfigValue -VarName "PROP_TEST_VAR" -DefaultValue $def -NonInteractive | Should -Be $def
            } -Seed 20260916 -NumRuns 30 -Description "default fallback"
            $result.Passed | Should -Be $true
        }

        It "property: NonInteractive throws when no value and no default" {
            $result = Invoke-Property {
                param($seed)
                Remove-Item Env:\PROP_TEST_VAR -ErrorAction SilentlyContinue
                Remove-Item Env:\PROP_TEST_ALIAS -ErrorAction SilentlyContinue
                { Get-ConfigValue -VarName "PROP_TEST_MISSING_$seed" -NonInteractive } | Should -Throw
            } -Seed 20260917 -NumRuns 20 -Description "noninteractive throw"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Resolve-StringPlaceholders property tests" -Tag "Property", "Config" {

    Context "Placeholder resolution invariants" {
        It "property: all placeholders resolved when map provided" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $names = @("OWNER", "PROJECT", "DOMAIN")
                $name = $names[$rng.Next($names.Count)]
                $values = @("Alice", "FRAD", ".test.com")
                $val = $values[$rng.Next($values.Count)]
                $text = "Hello {${name}} welcome to {${name}}"
                $map = @{ $name = $val }
                $resolved = Resolve-StringPlaceholders -Text $text -PlaceholderMap $map
                $resolved | Should -Be "Hello $val welcome to $val"
            } -Seed 20260918 -NumRuns 30 -Description "placeholders resolved"
            $result.Passed | Should -Be $true
        }

        It "property: empty text returns empty" {
            $result = Invoke-Property {
                param($seed)
                Resolve-StringPlaceholders -Text "" -PlaceholderMap @{ "X" = "Y" } | Should -Be ""
            } -Seed 20260919 -NumRuns 10 -Description "empty text"
            $result.Passed | Should -Be $true
        }

        It "property: no matching placeholders leaves text unchanged" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("no placeholders", "{X} not in map", "plain text")
                $text = $boundaries[$rng.Next($boundaries.Count)]
                Resolve-StringPlaceholders -Text $text -PlaceholderMap @{ "NOMATCH" = "val" } | Should -Be $text
            } -Seed 20260920 -NumRuns 20 -Description "no-match passthrough"
            $result.Passed | Should -Be $true
        }

        It "property: resolution is idempotent (no placeholders left after first pass)" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $val = "resolved_$seed"
                $text = "{OWNER}"
                $map = @{ "OWNER" = $val }
                $first = Resolve-StringPlaceholders -Text $text -PlaceholderMap $map
                $second = Resolve-StringPlaceholders -Text $first -PlaceholderMap $map
                $first | Should -Be $second
            } -Seed 20260921 -NumRuns 20 -Description "idempotent resolution"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Update-InstallJsonKey property tests" -Tag "Property", "Config" {

    Context "JSON key update round-trip" {
        It "property: string value round-trips correctly" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $boundaries = @("value_a", "value_b", "TEST", "")
                $val = $boundaries[$rng.Next($boundaries.Count)]
                $testFile = Join-Path $env:TEMP "prop-update-$seed.json"
                try {
                    '{"project": {"code": "OLD"}}' | Set-Content $testFile
                    Update-InstallJsonKey -Path $testFile -KeyPath "project.code" -Value $val
                    $content = Get-Content $testFile -Raw | ConvertFrom-Json
                    $content.project.code | Should -Be $val
                } finally {
                    if (Test-Path $testFile) { Remove-Item $testFile }
                }
            } -Seed 20260922 -NumRuns 30 -Description "string round-trip"
            $result.Passed | Should -Be $true
        }

        It "property: boolean value round-trips correctly" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $val = $rng.Next(2) -eq 0
                $testFile = Join-Path $env:TEMP "prop-bool-$seed.json"
                try {
                    '{"features": {"sentry": {"install": true}}}' | Set-Content $testFile
                    Update-InstallJsonKey -Path $testFile -KeyPath "features.sentry.install" -Value $val
                    $content = Get-Content $testFile -Raw | ConvertFrom-Json
                    $content.features.sentry.install | Should -Be $val
                } finally {
                    if (Test-Path $testFile) { Remove-Item $testFile }
                }
            } -Seed 20260923 -NumRuns 20 -Description "bool round-trip"
            $result.Passed | Should -Be $true
        }

        It "property: integer value round-trips correctly" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $val = $rng.Next(0, 10000)
                $testFile = Join-Path $env:TEMP "prop-int-$seed.json"
                try {
                    '{"features": {"opencode": {"count": 1}}}' | Set-Content $testFile
                    Update-InstallJsonKey -Path $testFile -KeyPath "features.opencode.count" -Value $val
                    $content = Get-Content $testFile -Raw | ConvertFrom-Json
                    $content.features.opencode.count | Should -Be $val
                } finally {
                    if (Test-Path $testFile) { Remove-Item $testFile }
                }
            } -Seed 20260924 -NumRuns 30 -Description "int round-trip"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Read-InstallJson invalid-input handling" -Tag "Property", "Config" {

    Context "Fail-closed on malformed JSON" {
        It "property: returns null for non-JSON strings" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $badInputs = @("not json", "{broken", "[]]]", "", "null", "undefined")
                $input = $badInputs[$rng.Next($badInputs.Count)]
                $testFile = Join-Path $env:TEMP "prop-badjson-$seed.json"
                try {
                    $input | Set-Content $testFile
                    Read-InstallJson -Path $testFile | Should -Be $null
                } finally {
                    if (Test-Path $testFile) { Remove-Item $testFile }
                }
            } -Seed 20260925 -NumRuns 30 -Description "malformed json null"
            $result.Passed | Should -Be $true
        }

        It "property: returns null for nonexistent file" {
            $result = Invoke-Property {
                param($seed)
                Read-InstallJson -Path "C:\nonexistent\path-$seed.json" | Should -Be $null
            } -Seed 20260926 -NumRuns 10 -Description "missing file null"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-SilentToggle property tests" -Tag "Property", "Config" {

    Context "Toggle precedence" {
        BeforeEach {
            $script:TestToggleFile = Join-Path $env:TEMP "prop-toggle-$(Get-Random).json"
            '{"features": {"sentry": {"install": true}}}' | Set-Content $script:TestToggleFile
            $env:ORCHESTRATOR_INSTALL_JSON = $script:TestToggleFile
        }

        AfterEach {
            if (Test-Path $script:TestToggleFile) { Remove-Item $script:TestToggleFile }
            Remove-Item Env:\ORCHESTRATOR_INSTALL_JSON -ErrorAction SilentlyContinue
            Remove-Item Env:\PROP_TOGGLE -ErrorAction SilentlyContinue
        }

        It "property: env var wins over install.json" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $vals = @("true", "false", "1", "0")
                $val = $vals[$rng.Next($vals.Count)]
                $env:PROP_TOGGLE = $val
                Get-SilentToggle -VarName "PROP_TOGGLE" | Should -Be $val
            } -Seed 20260927 -NumRuns 20 -Description "env beats json toggle"
            $result.Passed | Should -Be $true
        }

        It "property: DroneMode default is returned when nothing set" {
            $result = Invoke-Property {
                param($seed)
                Remove-Item Env:\PROP_TOGGLE -ErrorAction SilentlyContinue
                Get-SilentToggle -VarName "PROP_NONEXISTENT_$seed" -DefaultValue "false" -DroneMode | Should -Be "false"
            } -Seed 20260928 -NumRuns 20 -Description "drone default"
            $result.Passed | Should -Be $true
        }
    }
}

Describe "Get-DefaultDomainSuffix invariants" -Tag "Property", "Config" {

    Context "Domain suffix resolution" {
        It "property: env var override wins" {
            $result = Invoke-Property {
                param($seed)
                $rng = [System.Random]::new($seed)
                $suffixes = @(".test.com", ".example.org", ".custom.net")
                $suffix = $suffixes[$rng.Next($suffixes.Count)]
                $saved = $env:INTERCLAW_DOMAIN_SUFFIX
                try {
                    $env:INTERCLAW_DOMAIN_SUFFIX = $suffix
                    Get-DefaultDomainSuffix | Should -Be $suffix
                } finally {
                    $env:INTERCLAW_DOMAIN_SUFFIX = $saved
                }
            } -Seed 20260929 -NumRuns 20 -Description "domain suffix env override"
            $result.Passed | Should -Be $true
        }
    }
}
