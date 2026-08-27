#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Deploy Fleet Compose Builder Functions" -Tag "Deploy", "Regression" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Deploy\SalmonRun.Deploy.ps1'
        . $modulePath
    }

    Context "Add-AgentServiceToCompose" -Tag "Deploy" {
        It "accepts mandatory parameters and returns ordered dictionary" {
            $compose = [ordered]@{ services = [ordered]@{} }
            $agents = @(@{ Role='BASE'; Index=0; InstanceId='1'; AgentName='Agent-TST-BASE-1'; GatewayPort=20100 })
            $manifest = @{ Agent = @{ Suffix = 'secrets_bundle' } }
            $result = Add-AgentServiceToCompose -Compose $compose -Agents $agents -ProjectCode 'TST' -SovereigntyTier 'canada' -InstallWorkspaceRepos 'none' -BundleManifest $manifest -AgentSuffix 'secrets_bundle' -HasMultiple $false
            $result | Should -BeOfType [System.Collections.Specialized.OrderedDictionary]
            $result.services.Keys | Should -Contain 'oc-base'
        }
    }

    Context "Add-FleetServiceToCompose" -Tag "Deploy" {
        It "adds is-fleet service when fleet is enabled" {
            $compose = [ordered]@{ services = [ordered]@{} }
            $agents = @(@{ Role='BASE'; Index=0; InstanceId='1'; AgentName='Agent-TST-BASE-1'; GatewayPort=20100 })
            $result = Add-FleetServiceToCompose -Compose $compose -Agents $agents -ProjectCode 'TST' -BundleNameFleet 'fleet_secrets_bundle' -InstallWorkspaceRepos 'none' -PreserveFleet $false -FleetEnabled $true
            $result.services.Keys | Should -Contain 'is-fleet'
        }

        It "skips is-fleet when fleet is disabled" {
            $compose = [ordered]@{ services = [ordered]@{} }
            $agents = @(@{ Role='BASE'; Index=0; InstanceId='1'; AgentName='Agent-TST-BASE-1'; GatewayPort=20100 })
            $result = Add-FleetServiceToCompose -Compose $compose -Agents $agents -ProjectCode 'TST' -BundleNameFleet 'fleet_secrets_bundle' -InstallWorkspaceRepos 'none' -PreserveFleet $false -FleetEnabled $false
            $result.services.Keys | Should -Not -Contain 'is-fleet'
        }

        It "includes Docker healthcheck when fleet is enabled" {
            $compose = [ordered]@{ services = [ordered]@{} }
            $agents = @(@{ Role='BASE'; Index=0; InstanceId='1'; AgentName='Agent-TST-BASE-1'; GatewayPort=20100 })
            $result = Add-FleetServiceToCompose -Compose $compose -Agents $agents -ProjectCode 'TST' -BundleNameFleet 'fleet_secrets_bundle' -InstallWorkspaceRepos 'none' -PreserveFleet $false -FleetEnabled $true
            $result.services['is-fleet'].Contains('healthcheck') | Should -Be $true
            $result.services['is-fleet'].healthcheck.test[0] | Should -Be "CMD-SHELL"
            $result.services['is-fleet'].healthcheck.test[1] | Should -Match "curl -sf http://127.0.0.1:.*/health"
            $result.services['is-fleet'].healthcheck.start_period | Should -Be "30s"
        }
    }

    Context "Add-ComposeNetworksAndVolumes" -Tag "Deploy" {
        It "adds networks and agent volumes" {
            $compose = [ordered]@{ services = [ordered]@{}; networks = [ordered]@{}; volumes = [ordered]@{} }
            $agents = @(@{ Role='BASE'; Index=0; InstanceId='1'; AgentName='Agent-TST-BASE-1'; GatewayPort=20100 })
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents $agents -InstallFunnel 'false' -InstallWorkspaceRepos 'none' -HasMultiple $false
            $result.networks.Keys | Should -Contain 'service_net'
            $result.volumes.Keys | Should -Contain 'agent_config_oc-base'
            $result.volumes.Keys | Should -Contain 'agent_persist_oc-base'
        }
    }

    Context "Add-ComposeSecrets" -Tag "Deploy" {
        It "adds agent bundle secrets" {
            $compose = [ordered]@{ secrets = [ordered]@{} }
            $agents = @(@{ Role='BASE'; Index=0; InstanceId='1'; AgentName='Agent-TST-BASE-1'; GatewayPort=20100 })
            $manifest = @{ Agent = @{ Suffix = 'secrets_bundle' } }
            $result = Add-ComposeSecrets -Compose $compose -Agents $agents -ProjectCode 'TST' -BundleManifest $manifest -ProxyBundleName 'proxy_secrets_bundle' -CodingReadBundleName 'coding_read_secrets_bundle' -CodingWriteBundleName 'coding_write_secrets_bundle' -BundleNameFleet 'fleet_secrets_bundle' -BookkeepingBundleName 'bookkeeping_secrets_bundle' -InstallBookkeeping 'false' -FleetEnabled $false
            $result.secrets.Keys | Should -Contain 'TST_BASE_secrets_bundle'
            $result.secrets.Keys | Should -Contain 'gateway_password'
        }
    }

    Context "Compile-FleetComposeOutput" -Tag "Deploy" {
        It "throws on service without image reference" {
            $compose = [ordered]@{
                services = [ordered]@{
                    'no-image-svc' = [ordered]@{ image = '' }
                }
            }
            { Compile-FleetComposeOutput -Compose $compose -Agents @() -OutputPath 'test.yml' } | Should -Throw
        }
    }

    Context "Add-SidecarServicesToCompose — retired sidecars" -Tag "Deploy", "Regression" {
        BeforeAll {
            # Stubs for helpers the sidecar composer calls
            function Get-ServicePort { param($Service, $Type) return 21015 }
            function Get-NetworkNames { return @{ ServiceNet = 'service_net' } }
            function Get-InterclawRepoRoot { return $TestDrive }
            function Get-HomeDir { return "$TestDrive/home" }
            function Get-InterclawConstants { return @{ InterclawImage = 'ORCHESTRATOR:local' } }
        }

        It "does not emit is-hermes even when InstallHermes is true (retired 2026-08-21)" {
            $compose = [ordered]@{ services = [ordered]@{}; networks = [ordered]@{}; volumes = [ordered]@{}; secrets = [ordered]@{}; configs = [ordered]@{} }
            $result = Add-SidecarServicesToCompose -Compose $compose -ProjectCode 'TST' -InstallWorkspaceRepos 'none' `
                -ProxyBundleName 'proxy_secrets_bundle' -CodingReadBundleName 'cr' -CodingWriteBundleName 'cw' `
                -BookkeepingBundleName 'acc' -BookkeepingBundleSuffix 'secrets_bundle' `
                -InstallTailscale 'false' -InstallBrowserless 'false' `
                -InstallBookkeeping 'false' -InstallAqe 'false' -InstallFunnel 'false' `
                -InstallMarketer 'false' -InstallHermes 'true' `
                -MonitoringEnabled $false
            $result.services.Keys | Should -Not -Contain 'is-hermes'
        }


    }
}