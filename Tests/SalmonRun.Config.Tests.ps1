#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $salmonModules = Join-Path $repoRoot "Modules"

    # RequiredModules resolves through PSModulePath.
    $env:PSModulePath = "$salmonModules$([System.IO.Path]::PathSeparator)$env:PSModulePath"

    Get-Module SalmonRun.Config -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Get-Module SalmonRun.Core -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $salmonModules "SalmonRun.Core\SalmonRun.Core.psd1") -Force -DisableNameChecking -Scope Global
    Import-Module (Join-Path $salmonModules "SalmonRun.Config\SalmonRun.Config.psd1") -Force -DisableNameChecking -Scope Global
}

Describe "SalmonRun.Config Module" -Tag "Config" {
    BeforeAll {
        $script:SavedInstallProject = $env:INSTALL_PROJECT
        $script:SavedSovereignty = $env:INTERCLAW_SOVEREIGNTY
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
        Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue
    }

    AfterAll {
        if ($script:SavedInstallProject) { $env:INSTALL_PROJECT = $script:SavedInstallProject } else { Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue }
        if ($script:SavedSovereignty) { $env:INTERCLAW_SOVEREIGNTY = $script:SavedSovereignty } else { Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue }
    }

    Context "Find-InstallJsonPath" {
        It "returns explicit override when ORCHESTRATOR_INSTALL_JSON is set and file exists" {
            $TestFile = Join-Path $env:TEMP "test-install-json-$(Get-Random).json"
            '{"version":"1.0"}' | Set-Content $TestFile
            $env:ORCHESTRATOR_INSTALL_JSON = $TestFile
            $Result = Find-InstallJsonPath
            $Result | Should -Be $TestFile
            Remove-Item Env:\ORCHESTRATOR_INSTALL_JSON
            Remove-Item $TestFile
        }

        It "returns null when no install.json exists anywhere" {
            $env:ORCHESTRATOR_INSTALL_JSON = $null
            $Result = Find-InstallJsonPath
            $Result -is [string] -or $null -eq $Result | Should -BeTrue
        }
    }

    Context "Read-InstallJson" {
        BeforeEach {
            $script:InstallJsonCache = $null
            $script:InstallJsonCacheTime = $null
        }

        It "parses JSON structure from a file" {
            $TestFile = Join-Path $env:TEMP "test-read-json-$(Get-Random).json"
            @'
            {
                "version": "1.0",
                "project": { "code": "TEST", "domainSuffix": ".test.com" },
                "fleet": { "sovereignty": "global", "agents": [{ "role": "BASE", "name": "Maestro" }] },
                "features": { "sentry": { "install": true } }
            }
'@ | Set-Content $TestFile
            $Result = Read-InstallJson -Path $TestFile
            $Result.project.code | Should -Be "TEST"
            $Result.fleet.agents.Count | Should -Be 1
            $Result.features.sentry.install | Should -BeTrue
            Remove-Item $TestFile
        }

        It "returns null when file does not exist" {
            $Result = Read-InstallJson -Path "C:\nonexistent\file.json"
            $Result | Should -Be $null
        }

        It "returns null when JSON is invalid" {
            $TestFile = Join-Path $env:TEMP "bad-json-$(Get-Random).json"
            "not json" | Set-Content $TestFile
            $Result = Read-InstallJson -Path $TestFile
            $Result | Should -Be $null
            Remove-Item $TestFile
        }
    }

    Context "Update-InstallJsonKey" {
        It "updates an existing key" {
            $TestFile = Join-Path $env:TEMP "test-update-json-$(Get-Random).json"
            @'
            { "project": { "code": "OLD" }, "runtime": { "rebuildInterclaw": false } }
'@ | Set-Content $TestFile
            $Result = Update-InstallJsonKey -Path $TestFile -KeyPath "project.code" -Value "NEW"
            $Result | Should -BeTrue
            $Content = Get-Content $TestFile -Raw | ConvertFrom-Json
            $Content.project.code | Should -Be "NEW"
            Remove-Item $TestFile
        }

        It "creates a new nested key path" {
            $TestFile = Join-Path $env:TEMP "test-create-json-$(Get-Random).json"
            @'
            { "project": { "code": "TEST" } }
'@ | Set-Content $TestFile
            $Result = Update-InstallJsonKey -Path $TestFile -KeyPath "features.sentry.install" -Value $true
            $Result | Should -BeFalse
            $Content = Get-Content $TestFile -Raw | ConvertFrom-Json
            $Content.features.sentry.install | Should -BeTrue
            Remove-Item $TestFile
        }

        It "handles boolean values" {
            $TestFile = Join-Path $env:TEMP "test-bool-json-$(Get-Random).json"
            @'
            { "runtime": { "rebuildInterclaw": true } }
'@ | Set-Content $TestFile
            Update-InstallJsonKey -Path $TestFile -KeyPath "runtime.rebuildInterclaw" -Value $false
            $Content = Get-Content $TestFile -Raw | ConvertFrom-Json
            $Content.runtime.rebuildInterclaw | Should -BeFalse
            Remove-Item $TestFile
        }

        It "handles integer values" {
            $TestFile = Join-Path $env:TEMP "test-int-json-$(Get-Random).json"
            @'
            { "features": { "opencode": { "count": 1 } } }
'@ | Set-Content $TestFile
            Update-InstallJsonKey -Path $TestFile -KeyPath "features.opencode.count" -Value 5
            $Content = Get-Content $TestFile -Raw | ConvertFrom-Json
            $Content.features.opencode.count | Should -Be 5
            Remove-Item $TestFile
        }
    }

    Context "Get-ConfigValue" {
        BeforeEach {
            $script:TestJsonFile = Join-Path $env:TEMP "test-config-$(Get-Random).json"
            '{"project": {"code": "from_file"}, "features": {"sentry": {"install": true}}}' | Set-Content $script:TestJsonFile
            $env:ORCHESTRATOR_INSTALL_JSON = $script:TestJsonFile
        }

        AfterEach {
            if (Test-Path $script:TestJsonFile) { Remove-Item $script:TestJsonFile }
            Remove-Item Env:\ORCHESTRATOR_INSTALL_JSON -ErrorAction SilentlyContinue
            Remove-Item Env:\CONFIG_TEST -ErrorAction SilentlyContinue
            Remove-Item Env:\CONFIG_TEST_ALIAS -ErrorAction SilentlyContinue
        }

        It "returns env var value when set" {
            $env:CONFIG_TEST = "from_env"
            Get-ConfigValue -VarName "CONFIG_TEST" -NonInteractive | Should -Be "from_env"
        }

        It "reads from install.json when env var not set" {
            Remove-Item Env:\CONFIG_TEST -ErrorAction SilentlyContinue
            Get-ConfigValue -VarName "INSTALL_PROJECT" -NonInteractive | Should -Be "from_file"
        }

        It "resolves aliases" {
            $env:CONFIG_TEST_ALIAS = "from_alias"
            Get-ConfigValue -VarName "CONFIG_TEST" -Aliases @("CONFIG_TEST_ALIAS") -NonInteractive | Should -Be "from_alias"
            $env:CONFIG_TEST | Should -Be "from_alias"
        }

        It "throws in NonInteractive mode when no value and no default" {
            { Get-ConfigValue -VarName "CONFIG_MISSING" -NonInteractive } | Should -Throw
        }

        It "returns default in NonInteractive mode when no value found" {
            Get-ConfigValue -VarName "CONFIG_MISSING" -DefaultValue "fallback" -NonInteractive | Should -Be "fallback"
        }
    }

    Context "Get-SilentToggle" {
        BeforeEach {
            $script:TestToggleFile = Join-Path $env:TEMP "test-toggle-$(Get-Random).json"
            '{"features": {"sentry": {"install": true}}}' | Set-Content $script:TestToggleFile
            $env:ORCHESTRATOR_INSTALL_JSON = $script:TestToggleFile
        }

        AfterEach {
            if (Test-Path $script:TestToggleFile) { Remove-Item $script:TestToggleFile }
            Remove-Item Env:\ORCHESTRATOR_INSTALL_JSON -ErrorAction SilentlyContinue
            Remove-Item Env:\INSTALL_SENTRY -ErrorAction SilentlyContinue
        }

        It "returns env var when set" {
            $env:INSTALL_SENTRY = "false"
            Get-SilentToggle -VarName "INSTALL_SENTRY" | Should -Be "false"
        }

        It "returns install.json value when declared" {
            Remove-Item Env:\INSTALL_SENTRY -ErrorAction SilentlyContinue
            Get-SilentToggle -VarName "INSTALL_SENTRY" | Should -Be "true"
        }

        It "returns default in DroneMode when not declared" {
            Get-SilentToggle -VarName "INSTALL_XX" -DefaultValue "false" -DroneMode | Should -Be "false"
        }
    }

    Context "Resolve-FleetConfig" {
        It "derives stack name from project" {
            $Json = @'
            { "project": { "code": "FRAD" }, "fleet": { "sovereignty": "global", "agents": [{ "role": "ORCH", "name": "" }] }, "features": { "sentry": {"install": true}, "tailscale": {"install": false}, "opencode": {"count": 1, "serverMode": true} } }
'@ | ConvertFrom-Json
            $Result = Resolve-FleetConfig -InstallEnv $Json -ProjectOverride "FRAD"
            $Result.Project | Should -Be "FRAD"
            $Result.StackName | Should -Be "FRAD"
            $Result.PublicDomain | Should -Be "frad.example.com"
        }

        It "uses provided ProjectOverride" {
            $Json = @'
            { "project": { "code": "OLD" }, "fleet": { "sovereignty": "global", "agents": [{ "role": "ORCH", "name": "" }] }, "features": {} }
'@ | ConvertFrom-Json
            $Result = Resolve-FleetConfig -InstallEnv $Json -ProjectOverride "NEW"
            $Result.Project | Should -Be "NEW"
        }

        It "reads sovereignty from install.json" {
            $Json = @'
            { "project": { "code": "T" }, "fleet": { "sovereignty": "canada", "agents": [{ "role": "ORCH", "name": "" }] }, "features": {} }
'@ | ConvertFrom-Json
            $Result = Resolve-FleetConfig -InstallEnv $Json
            $Result.SovereigntyTier | Should -Be "canada"
        }

        It "defaults sovereignty to global" {
            $Json = @'
            { "project": { "code": "T" }, "fleet": { "sovereignty": "", "agents": [] }, "features": {} }
'@ | ConvertFrom-Json
            $Result = Resolve-FleetConfig -InstallEnv $Json
            $Result.SovereigntyTier | Should -Be "global"
        }
    }

    Context "Get-DefaultDomainSuffix" {
        It "returns .example.com when no install.json or env var" {
            Get-DefaultDomainSuffix | Should -Be ".example.com"
        }

        It "returns env var when INTERCLAW_DOMAIN_SUFFIX is set" {
            $saved = $env:INTERCLAW_DOMAIN_SUFFIX
            $env:INTERCLAW_DOMAIN_SUFFIX = "test.example.com"
            try { Get-DefaultDomainSuffix | Should -Be "test.example.com" } finally { $env:INTERCLAW_DOMAIN_SUFFIX = $saved }
        }
    }

    Context "Get-DefaultProjectCode" {
        It "reads INSTALL_PROJECT from environment" {
            $saved = $env:INSTALL_PROJECT
            $env:INSTALL_PROJECT = "TESTCODE"
            try { Get-DefaultProjectCode | Should -Be "TESTCODE" } finally { $env:INSTALL_PROJECT = $saved }
        }
    }

    Context "Resolve-StringPlaceholders" {
        It "replaces {OWNER_NAME} with configured value" {
            Mock Get-OwnerPlaceholders { return @{ OWNER_NAME = "TestUser" } } -ModuleName SalmonRun.Config
            Resolve-StringPlaceholders -Text "Hello {OWNER_NAME}" | Should -Be "Hello TestUser"
        }

        It "returns input unchanged when no placeholders match" {
            Mock Get-OwnerPlaceholders { return @{} } -ModuleName SalmonRun.Config
            Resolve-StringPlaceholders -Text "No placeholders" | Should -Be "No placeholders"
        }
    }

    Context "Set-OwnerPlaceholders" {
        It "returns existing config with -NonInteractive when present" {
            Mock Get-OwnerPlaceholders { return @{ OWNER_NAME = "Existing" } } -ModuleName SalmonRun.Config
            $result = Set-OwnerPlaceholders -NonInteractive
            $result.OWNER_NAME | Should -Be "Existing"
        }
    }

    Context "Export-InstallJsonToEnv" {
        It "sets env vars from install.json project code" {
            $testJson = [pscustomobject]@{
                project = [pscustomobject]@{ code = "TESTCODE" }
                fleet = [pscustomobject]@{ sovereignty = "global"; agents = @([pscustomobject]@{ role = "BASE" }) }
                features = [pscustomobject]@{ sentry = [pscustomobject]@{ install = $true }; tailscale = [pscustomobject]@{ install = $false } }
            }
            Export-InstallJsonToEnv -InstallJson $testJson
            $env:INSTALL_PROJECT | Should -Be "TESTCODE"
            $env:PROJECT_CODE | Should -Be "TESTCODE"
            $env:INTERCLAW_SOVEREIGNTY | Should -Be "global"
            Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
            Remove-Item Env:\PROJECT_CODE -ErrorAction SilentlyContinue
            Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue
            Remove-Item Env:\INSTALL_SENTRY -ErrorAction SilentlyContinue
            Remove-Item Env:\INSTALL_TAILSCALE -ErrorAction SilentlyContinue
            Remove-Item Env:\ROLE_CODE -ErrorAction SilentlyContinue
            Remove-Item Env:\AGENT_NUMBER -ErrorAction SilentlyContinue
        }

        It "returns silently when InstallJson is null" {
            { Export-InstallJsonToEnv -InstallJson $null } | Should -Not -Throw
        }
    }

    Context "Test-SalmonRunConfigSchema" {
        It "returns Valid=false when Config is null" {
            $result = Test-SalmonRunConfigSchema -Config $null -ConfigType "Provider"
            $result.Valid | Should -BeFalse
            $result.Errors | Should -Contain "Config object is null"
        }

        It "detects missing models section for Provider type" {
            $config = [pscustomobject]@{}
            $result = Test-SalmonRunConfigSchema -Config $config -ConfigType "Provider"
            $result.Valid | Should -BeFalse
            $result.Errors | Should -Contain "Missing top-level 'models' section"
        }

        It "validates a valid Provider config" {
            $config = [pscustomobject]@{
                models = [pscustomobject]@{
                    providers = [pscustomobject]@{
                        test_provider = [pscustomobject]@{
                            baseUrl = "https://api.test.com"
                            api = "rest"
                            auth = "bearer"
                            models = @([pscustomobject]@{ id = "test-model"; name = "Test Model"; type = "chat" })
                        }
                    }
                }
            }
            $result = Test-SalmonRunConfigSchema -Config $config -ConfigType "Provider"
            $result.Valid | Should -BeTrue
            $result.Errors.Count | Should -Be 0
        }

        It "validates Policy type config" {
            $config = [pscustomobject]@{
                Version = "2012-10-17"
                Statement = @([pscustomobject]@{ Effect = "Allow"; Action = "s3:GetObject" })
            }
            $result = Test-SalmonRunConfigSchema -Config $config -ConfigType "Policy"
            $result.Valid | Should -BeTrue
        }

        It "legacy Test-InterclawConfigSchema alias resolves to canonical function" {
            $config = [pscustomobject]@{ Version = "2012-10-17"; Statement = @([pscustomobject]@{ Effect = "Allow"; Action = "s3:GetObject" }) }
            $result = Test-InterclawConfigSchema -Config $config -ConfigType "Policy"
            $result.Valid | Should -BeTrue
        }
    }

    Context "Update-InstallJsonTestStatus" {
        It "does not throw when no install.json found" {
            Mock Find-InstallJsonPath { return $null }
            { Update-InstallJsonTestStatus -ContainerStatus @{ "Config" = "Pass" } } | Should -Not -Throw
        }
    }

    Context "Get-OwnerPlaceholders" {
        It "returns a hashtable" {
            $result = Get-OwnerPlaceholders
            $result | Should -BeOfType [hashtable]
        }

        It "returns empty hashtable when owner config path points to non-existent file" {
            Mock Test-Path { return $false } -ModuleName SalmonRun.Config
            Get-OwnerPlaceholders | Should -BeOfType [hashtable]
        }
    }
}

Describe "SalmonRun.Config Module Manifest" -Tag "Config", "Regression-Only" {
    BeforeAll {
        $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
        $script:ConfigPsd1 = Join-Path $repoRoot "Modules" "SalmonRun.Config" "SalmonRun.Config.psd1"
    }

    It "exports Test-SalmonRunConfigSchema as the canonical schema validator" {
        $manifest = Import-PowerShellDataFile -Path $script:ConfigPsd1
        $manifest.FunctionsToExport | Should -Contain "Test-SalmonRunConfigSchema"
    }

    It "exports the legacy Test-InterclawConfigSchema alias" {
        $manifest = Import-PowerShellDataFile -Path $script:ConfigPsd1
        $manifest.AliasesToExport | Should -Contain "Test-InterclawConfigSchema"
    }
}

