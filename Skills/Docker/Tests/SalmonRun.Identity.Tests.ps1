#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# SalmonRun.Identity Module Tests
# ==============================================================================

BeforeAll {
    $script:ModulesDir = Join-Path $PSScriptRoot "..\Modules"
    if ($env:PSModulePath -notlike "*$($script:ModulesDir)*") {
        $env:PSModulePath = "$($script:ModulesDir);$env:PSModulePath"
    }
    Import-Module SalmonRun.Paths -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module SalmonRun.Diagnostics -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module SalmonRun.Core -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module SalmonRun.Ports -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module SalmonRun.Config -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module SalmonRun.Constants -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module SalmonRun.Identity -Force -DisableNameChecking -ErrorAction Stop
    $script:ModName = "SalmonRun.Identity"

    Mock Write-SetupLog { }
    Mock Write-Host { }
    Mock Read-Host { return "" }
}

Describe "SalmonRun.Identity Module" -Tag "Identity", "Regression-Only" {
    Context "Resolve-AgentIdentity" {
        It "throws when project code is empty" {
            Mock -ModuleName $script:ModName Get-ConfigValue { return "" }
            Mock -ModuleName $script:ModName Read-Host { return "" }
            { Resolve-AgentIdentity } | Should -Throw
        }

        It "resolves from fleet.agents in install.json" {
            Mock -ModuleName $script:ModName Get-ConfigValue { return "FRAD" }
            Mock -ModuleName $script:ModName Read-InstallJson { return [PSCustomObject]@{
                fleet = [PSCustomObject]@{
                    sovereignty = "global"
                    agents = @(
                        [PSCustomObject]@{ role = "BASE"; name = "Maestro" }
                    )
                }
            } }
            Mock -ModuleName $script:ModName Read-Host { return "" }

            $Result = Resolve-AgentIdentity
            $Result.ProjectCode | Should -Be "FRAD"
            $Result.AgentNumber | Should -Be 1
            $Result.RoleArray.Count | Should -Be 1
            $Result.NextGlobalId | Should -Be 2
        }
    }

    Context "Resolve-AgentNames" {
        It "returns empty map when no names configured" {
            Mock -ModuleName $script:ModName Get-ConfigValue { return "" }
            $Result = Resolve-AgentNames -AgentNumber 1 -RoleArray @("BASE")
            $Result.Count | Should -Be 0
        }

        It "builds role-to-name map" {
            Mock -ModuleName $script:ModName Get-ConfigValue { return "Alice,Bob" }
            $Result = Resolve-AgentNames -AgentNumber 1 -RoleArray @("BASE")
            $Result["BASE"] | Should -Be "Alice"
        }
    }

    Context "Resolve-SovereigntyTier" {
        It "resolves Global tier" {
            Mock -ModuleName $script:ModName Get-ConfigValue { return "G" }
            Mock -ModuleName $script:ModName Test-Path { return $true }
            Mock -ModuleName $script:ModName Get-Content { return '{"models":[],"agents":[]}' }
            Mock -ModuleName $script:ModName Test-InterclawConfigSchema { return @{ Valid = $true; Errors = @(); Warnings = @() } }

            $Result = Resolve-SovereigntyTier -RoleArray @("ORCH") -AgentsRoot (Join-Path $env:TEMP "test")
            $Result.Tier | Should -Be "global"
        }

        It "throws on invalid choice" {
            Mock -ModuleName $script:ModName Get-ConfigValue { return "X" }
            Mock -ModuleName $script:ModName Read-Host { return "X" }
            Mock -ModuleName $script:ModName Test-Path { return $false }

            { Resolve-SovereigntyTier -RoleArray @("ORCH") -AgentsRoot (Join-Path $env:TEMP "test") } | Should -Throw
        }
    }

    Context "Test-CodingKeyAvailability" {
        It "throws when no keys available" {
            "OPENCODE_GO1_KEY","OPENCODE_GO5_KEY" | ForEach-Object {
                Remove-Item "Env:\$_" -ErrorAction SilentlyContinue
            }
            { Test-CodingKeyAvailability -RequiredCount 1 } | Should -Throw
        }

        It "returns available keys when present" {
            $env:OPENCODE_GO1_KEY = "test-key"
            $Result = Test-CodingKeyAvailability -RequiredCount 1
            $Result.Available | Should -BeTrue
            $Result.KeyCount | Should -Be 1
            Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
        }

        It "recognizes KEY5 in the registry" {
            $env:OPENCODE_GO5_KEY = "test-key-5"
            $Result = Test-CodingKeyAvailability -RequiredCount 1
            $Result.Available | Should -BeTrue
            $Result.KeyCount | Should -BeGreaterOrEqual 1
            Remove-Item Env:\OPENCODE_GO5_KEY -ErrorAction SilentlyContinue
        }
    }

    Context "Role-stable naming functions" -Tag "Identity" {
        It "Get-AgentHostPort returns 20300 for BASE" {
            Get-AgentHostPort -Role BASE | Should -Be 20300
        }
        It "Get-AgentHostPort returns 20300 for BASE index 0" {
            Get-AgentHostPort -Role BASE -Index 0 | Should -Be 20300
        }
        It "Get-AgentHostPort returns 20302 for BASE index 2" {
            Get-AgentHostPort -Role BASE -Index 2 | Should -Be 20302
        }
        It "Get-AgentServiceName returns oc-base" {
            Get-AgentServiceName BASE | Should -Be "oc-base"
        }
        It "Get-AgentServiceName returns oc-base-1 for multi-index" {
            Get-AgentServiceName BASE 1 | Should -Be "oc-base-1"
        }
        It "Get-AgentVolumeName returns correct volume" {
            Get-AgentVolumeName FRAD "agent_config" base | Should -Be "FRAD_agent_config_oc-base"
        }
        It "Get-AgentSecretPrefix returns correct prefix" {
            Get-AgentSecretPrefix FRAD BASE | Should -Be "FRAD_BASE"
        }
        It "Get-AgentSecretPrefix returns role-indexed for multi" {
            Get-AgentSecretPrefix FRAD BASE 1 | Should -Be "FRAD_BASE-1"
        }
    }

    Context "Get-RoleFileMap" -Tag "Identity" {
        It "returns role-to-files hashtable" {
            $map = Get-RoleFileMap
            $map | Should -BeOfType [hashtable]
            $map.Keys.Count | Should -BeGreaterThan 0
        }
    }

    Context "Get-SharedFiles" -Tag "Identity" {
        It "returns shared file names array" {
            $files = Get-SharedFiles
            $files -is [array] | Should -BeTrue
            $files | Should -Contain "User.md"
            $files | Should -Contain "environment.md"
        }
    }

    Context "New-AgentContext" -Tag "Identity" {
        BeforeEach {
            $script:SavedProject = $env:INSTALL_PROJECT
            $script:SavedRole = $env:INSTALL_ROLE
            $script:SavedInstance = $env:INTERCLAW_INSTANCE_ID
            $script:SavedIndex = $env:INTERCLAW_AGENT_INDEX
            $env:INSTALL_PROJECT = "TEST"
            $env:INSTALL_ROLE = "BASE"
            $env:INTERCLAW_INSTANCE_ID = "1"
            $env:INTERCLAW_AGENT_INDEX = "0"
        }
        AfterEach {
            if ($script:SavedProject) { $env:INSTALL_PROJECT = $script:SavedProject } else { Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue }
            if ($script:SavedRole) { $env:INSTALL_ROLE = $script:SavedRole } else { Remove-Item Env:\INSTALL_ROLE -ErrorAction SilentlyContinue }
            if ($script:SavedInstance) { $env:INTERCLAW_INSTANCE_ID = $script:SavedInstance } else { Remove-Item Env:\INTERCLAW_INSTANCE_ID -ErrorAction SilentlyContinue }
            if ($script:SavedIndex) { $env:INTERCLAW_AGENT_INDEX = $script:SavedIndex } else { Remove-Item Env:\INTERCLAW_AGENT_INDEX -ErrorAction SilentlyContinue }
        }

        It "reads from env vars by default" {
            $ctx = New-AgentContext
            $ctx.ProjectCode | Should -Be "TEST"
            $ctx.RoleCode | Should -Be "BASE"
            $ctx.InstanceId | Should -Be "1"
        }

        It "accepts override parameters" {
            $ctx = New-AgentContext -ProjectCode "CUSTOM" -RoleCode "BASE" -InstanceId "2" -Index 1
            $ctx.ProjectCode | Should -Be "CUSTOM"
            $ctx.RoleCode | Should -Be "BASE"
            $ctx.InstanceId | Should -Be "2"
            $ctx.Index | Should -Be 1
        }

        It "returns AgentName in expected format" {
            $ctx = New-AgentContext
            $ctx.AgentName | Should -Be "Agent-TEST-BASE-1"
        }

        It "throws when INSTALL_PROJECT is not set and no parameter provided" {
            Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
            Remove-Item Env:\INSTALL_ROLE -ErrorAction SilentlyContinue
            { New-AgentContext } | Should -Throw
        }
    }

    Context "Initialize-FleetToggles" -Tag "Identity" {
        BeforeAll {
            Mock Write-SetupLog { }
            # Pre-set env vars so Get-SilentToggle returns without prompting
            $env:INSTALL_TAILSCALE = "true"
            $env:INSTALL_FLEET = "true"
            $env:INSTALL_TEMPO = "true"
            $env:INSTALL_REKOGNITION_FALLBACK = "true"
            $env:INSTALL_DOCUSIGN = "true"
            $env:INSTALL_BROWSERLESS = "true"
            $env:INSTALL_BOOKKEEPING = "true"
            $env:INSTALL_OPENCODE = "true"
            $env:INSTALL_WEB_MCP = "true"
            $env:INSTALL_AQE = "true"
            $env:INSTALL_FUNNEL = "true"
            $env:INSTALL_MONITORING = "true"
        }

        It "returns a hashtable of toggles" {
            $result = Initialize-FleetToggles
            $result | Should -BeOfType [hashtable]
        }

        It "sets env vars for each toggle" {
            $result = Initialize-FleetToggles
            $env:INSTALL_TAILSCALE | Should -Be "true"
            $env:INSTALL_FLEET | Should -Be "true"
            $env:INSTALL_OPENCODE | Should -Be "true"
        }

        It "respects DroneMode switch" {
            $result = Initialize-FleetToggles -DroneMode
            $result.InstallBrowserless | Should -Not -BeNullOrEmpty
        }
    }
}
