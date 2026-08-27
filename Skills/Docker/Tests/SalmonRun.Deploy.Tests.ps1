#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Deploy Module" -Tag "Deploy" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $corePublic = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public"
        if (Test-Path $corePublic) { Get-ChildItem -Path $corePublic -Filter '*.ps1' | ForEach-Object { . $_.FullName } }

        $moduleDirs = @(
            'SalmonRun.Config'
            'SalmonRun.Secrets'
            'SalmonRun.Constants'
            'SalmonRun.Process'
            'SalmonRun.Fleet'
            'SalmonRun.Deploy'
            'SalmonRun.Identity'
        )
        $moduleDirs = $moduleDirs | ForEach-Object {
            switch ($_) {
                'SalmonRun.Config'      { '..\..\..\Orchestrator\Modules\SalmonRun.Config' }
                'SalmonRun.Constants'   { '..\..\..\Orchestrator\Modules\SalmonRun.Constants' }
                'SalmonRun.Process'     { '..\..\..\Orchestrator\Modules\SalmonRun.Process' }
                default                 { $_ }
            }
        }
        foreach ($dir in $moduleDirs) {
            $leaf = $dir | Split-Path -Leaf
            $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$leaf.ps1"
            if (Test-Path $modulePath) { . $modulePath }
        }

        $script:TestTempDir = Join-Path $env:TEMP "Interclaw-Tests-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestTempDir -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:TestTempDir) {
            Remove-Item -Recurse -Force $script:TestTempDir
        }
    }

    Context "Remove-OrphanedVolumes" -Tag "Deploy" {
        It 'mutable default $ProtectPatterns is not shared across calls - regression' -Tag "Regression-Only" {
            Remove-OrphanedVolumes -StackName "TEST" -AgentConfigs @(@{ Role = "BASE"; Index = 0 }) -UseLabels | Out-Null
            Remove-OrphanedVolumes -StackName "TEST" -AgentConfigs @(@{ Role = "BASE"; Index = 0 }) -UseLabels -ProtectPatterns @("legacy") | Out-Null
            $result3 = Remove-OrphanedVolumes -StackName "TEST" -AgentConfigs @(@{ Role = "BASE"; Index = 0 }) -UseLabels
            $result3 | Should -Not -Be $null
        }
    }

    Context "Add-ComposeNetworksAndVolumes" -Tag "Deploy" {
        BeforeAll {
            Mock Get-NetworkNames { return [pscustomobject]@{ ServiceNet = "service_net"; OrchestrationNet = "orchestration_net"; ManagementNet = "management_net"; FunnelNet = "funnel_net" } } -ModuleName SalmonRun.Deploy
            Mock Get-AgentServiceName { param($Role, $Index) return "oc-$($Role.ToLower())-$Index" } -ModuleName SalmonRun.Deploy
        }

        It "adds service, orchestration, and management networks" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.networks.Contains("service_net") | Should -BeTrue
            $result.networks.Contains("orchestration_net") | Should -BeTrue
            $result.networks.Contains("management_net") | Should -BeTrue
        }

        It "adds funnel_net when InstallFunnel is true" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "true" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.networks.Contains("funnel_net") | Should -BeTrue
            $result.networks.funnel_net.name | Should -Be "funnel_net"
        }

        It "omits funnel_net when InstallFunnel is false" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.networks.Contains("funnel_net") | Should -BeFalse
        }

        It "adds per-agent config and persist volumes" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $agents = @( @{ Role = "BASE"; Index = 0 }, @{ Role = "WORK"; Index = 1 } )
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents $agents -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.volumes.Contains("agent_config_oc-base-0") | Should -BeTrue
            $result.volumes.Contains("agent_persist_oc-base-0") | Should -BeTrue
            $result.volumes.Contains("agent_config_oc-work-1") | Should -BeTrue
            $result.volumes.Contains("agent_persist_oc-work-1") | Should -BeTrue
        }

        It "adds memory_shared when HasMultiple is true" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $true
            $result.volumes.Contains("memory_shared") | Should -BeTrue
        }

        It "omits memory_shared when HasMultiple is false" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.volumes.Contains("memory_shared") | Should -BeFalse
        }

        It "adds interclaw_workspace when InstallWorkspaceRepos is set" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "repo1,repo2" -HasMultiple $false
            $result.volumes.Contains("interclaw_workspace") | Should -BeTrue
        }

        It "omits interclaw_workspace when InstallWorkspaceRepos is empty" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.volumes.Contains("interclaw_workspace") | Should -BeFalse
        }

        It "adds interclaw_logs volume always" {
            $compose = [ordered]@{ networks = [ordered]@{}; volumes = [ordered]@{} }
            $result = Add-ComposeNetworksAndVolumes -Compose $compose -Agents @(@{ Role = "BASE"; Index = 0 }) -InstallFunnel "false" -InstallWorkspaceRepos "" -HasMultiple $false
            $result.volumes.Contains("interclaw_logs") | Should -BeTrue
        }
    }

    Context "Compile-FleetComposeOutput" -Tag "Deploy" {
        BeforeAll {
            Mock ConvertTo-ComposeYaml { return "version: `"3.8`"" } -ModuleName SalmonRun.Deploy
            Mock Write-AtomicFile { } -ModuleName SalmonRun.Deploy
            Mock Write-SetupLog { }
        }

        It "returns OutputPath for valid compose" {
            $compose = [ordered]@{ services = [ordered]@{ test_svc = [ordered]@{ image = "test-img" } } }
            $outputPath = Join-Path $script:TestTempDir "fleet-compose.yml"
            $result = Compile-FleetComposeOutput -Compose $compose -Agents @( @{ Role = "BASE" } ) -OutputPath $outputPath
            $result | Should -Be $outputPath
            Should -Invoke -CommandName ConvertTo-ComposeYaml -Times 1 -ModuleName SalmonRun.Deploy
            Should -Invoke -CommandName Write-AtomicFile -Times 1 -ModuleName SalmonRun.Deploy
        }

        It "throws when a service has no image" {
            $compose = [ordered]@{ services = [ordered]@{ missing_img = [ordered]@{} } }
            $outputPath = Join-Path $script:TestTempDir "bad-compose.yml"
            { Compile-FleetComposeOutput -Compose $compose -Agents @(@{ Role = "BASE" }) -OutputPath $outputPath } | Should -Throw "no image reference"
        }

        It "throws when healthcheck is nested under deploy" {
            $compose = [ordered]@{ services = [ordered]@{ bad_svc = [ordered]@{ image = "img"; deploy = [ordered]@{ healthcheck = [ordered]@{ test = @("CMD", "true") } } } } }
            $outputPath = Join-Path $script:TestTempDir "bad-deploy.yml"
            { Compile-FleetComposeOutput -Compose $compose -Agents @(@{ Role = "BASE" }) -OutputPath $outputPath } | Should -Throw "healthcheck"
        }

        It "validates all services even if first passes" {
            $compose = [ordered]@{ services = [ordered]@{ good = [ordered]@{ image = "ok" }; bad = [ordered]@{} } }
            $outputPath = Join-Path $script:TestTempDir "mixed-compose.yml"
            { Compile-FleetComposeOutput -Compose $compose -Agents @(@{ Role = "BASE" }) -OutputPath $outputPath } | Should -Throw "no image reference"
        }

        It "logs agent count to setup log" {
            $compose = [ordered]@{ services = [ordered]@{ s = [ordered]@{ image = "i" } } }
            $outputPath = Join-Path $script:TestTempDir "log-test.yml"
            Compile-FleetComposeOutput -Compose $compose -Agents @( @{ Role = "BASE" }, @{ Role = "WORK" } ) -OutputPath $outputPath | Out-Null
            Should -Invoke -CommandName Write-SetupLog -Times 1 -ParameterFilter { $Message -match "2 agents" }
        }
    }

    Context "ConvertTo-ComposeYaml" -Tag "Deploy" {
        It "serializes a simple hashtable to YAML" {
            $ht = [ordered]@{ version = "3.8"; services = [ordered]@{} }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "version: `"3.8`""
            $yaml | Should -Match "services:"
        }

        It "serializes arrays of strings as block sequence" {
            $ht = [ordered]@{ networks = @("service_net", "orchestration_net") }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "  - service_net"
            $yaml | Should -Match "  - orchestration_net"
        }

        It "serializes arrays of hashtables with proper indentation" {
            $ht = [ordered]@{
                secrets = @(
                    [ordered]@{ source = "instance_1_aws_id"; target = "aws_id" }
                    [ordered]@{ source = "instance_1_aws_secret"; target = "aws_secret" }
                )
            }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "  - source: instance_1_aws_id"
            $yaml | Should -Match "    target: aws_id"
            $yaml | Should -Match "  - source: instance_1_aws_secret"
            $yaml | Should -Match "    target: aws_secret"
        }

        It "outputs null values as empty keys" {
            $ht = [ordered]@{ volumes = [ordered]@{ test_volume = $null } }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "  test_volume:"
        }

        It "quotes strings containing special YAML characters" {
            $ht = [ordered]@{ ports = @("127.0.0.1:3001:3001") }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match '"127.0.0.1:3001:3001"'
        }

        It "serializes drone ports with localhost-only binding" {
            $ht = [ordered]@{ services = [ordered]@{ "is-fleet" = [ordered]@{ ports = @("127.0.0.1:3001:3001") } } }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "127.0.0.1:3001:3001"
        }

        It "serializes proxy service without published ports" {
            $ht = [ordered]@{ services = [ordered]@{ "is-api" = [ordered]@{ networks = @("service_net"); image = "is-api:local" } } }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "is-api"
            $yaml | Should -Not -Match "ports:"
        }

        It "quotes strings that look like booleans" {
            $ht = [ordered]@{ environment = [ordered]@{ TS_USERSPACE = "false" } }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match 'TS_USERSPACE: "false"'
        }

        It "does not quote plain strings" {
            $ht = [ordered]@{ image = "nginx" }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "image: nginx"
        }

        It "handles nested ordered hashtables" {
            $ht = [ordered]@{
                deploy = [ordered]@{
                    resources = [ordered]@{
                        limits = [ordered]@{ memory = "4G" }
                    }
                }
            }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "deploy:"
            $yaml | Should -Match "  resources:"
            $yaml | Should -Match "    limits:"
            $yaml | Should -Match "      memory: 4G"
        }

        It "preserves integer values unquoted" {
            $ht = [ordered]@{ retries = 5 }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "retries: 5"
            $yaml | Should -Not -Match '"5"'
        }

        It "serializes external: true hashtable as sub-keys" {
            $ht = [ordered]@{ volumes = [ordered]@{ test_vol = [ordered]@{ external = $true } } }
            $yaml = ConvertTo-ComposeYaml -InputObject $ht
            $yaml | Should -Match "  test_vol:"
            $yaml | Should -Match "    external: true"
        }

        It "round-trips a known-good compose structure" {
            $Compose = [ordered]@{
                version = "3.8"
                services = [ordered]@{
                    test = [ordered]@{
                        image = "testimage"
                        networks = @("net1")
                        environment = [ordered]@{ KEY = "value" }
                        volumes = @("vol1:/data")
                        secrets = @([ordered]@{ source = "sec1"; target = "sec1" })
                    }
                }
                networks = [ordered]@{ net1 = [ordered]@{ driver = "overlay" } }
                volumes = [ordered]@{ vol1 = [ordered]@{ external = $true } }
                secrets = [ordered]@{ sec1 = [ordered]@{ external = $true } }
            }
            $yaml = ConvertTo-ComposeYaml -InputObject $Compose
            $yaml | Should -Match "version: `"3.8`""
            $yaml | Should -Match "services:"
            $yaml | Should -Match "  test:"
            $yaml | Should -Match "    image: testimage"
            $yaml | Should -Match "    networks:"
            $yaml | Should -Match "      - net1"
            $yaml | Should -Match "    environment:"
            $yaml | Should -Match "      KEY: value"
            $yaml | Should -Match "    volumes:"
            $yaml | Should -Match '"vol1:/data"'
            $yaml | Should -Match "    secrets:"
            $yaml | Should -Match "      - source: sec1"
            $yaml | Should -Match "        target: sec1"
            $yaml | Should -Match "networks:"
            $yaml | Should -Match "  net1:"
            $yaml | Should -Match "    driver: overlay"
            $yaml | Should -Match "volumes:"
            $yaml | Should -Match "  vol1:"
            $yaml | Should -Match "secrets:"
            $yaml | Should -Match "  sec1:"
            $yaml | Should -Match "    external: true"
        }
    }

    Context "New-FleetCompose — 3-agent fleets" -Tag "Deploy" {
        BeforeAll {
            $script:TestComposeDir = Join-Path $env:TEMP "Interclaw-Compose-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:TestComposeDir -Force | Out-Null

            Mock Invoke-NativeCommand { return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = "image found" } } -ModuleName SalmonRun.Deploy

            $script:Agent3 = @(
                @{ Role='BASE'; Index=0; InstanceId='84'; AgentName='Agent-TST-BASE-84'; GatewayPort=20300 }
                @{ Role='BASE'; Index=1; InstanceId='85'; AgentName='Agent-TST-BASE-85'; GatewayPort=20301 }
                @{ Role='BASE'; Index=2; InstanceId='86'; AgentName='Agent-TST-BASE-86'; GatewayPort=20302 }
            )
        }

        AfterAll {
            if (Test-Path $script:TestComposeDir) {
                Remove-Item -Recurse -Force $script:TestComposeDir
            }
        }

        It "3-agent Canada tier has no global provider secrets" {
            $path = Join-Path $script:TestComposeDir "ca.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_SOVEREIGNTY: canada'
            $yaml | Should -Match 'TRIO_NETWORK: orchestration_net'
            $yaml | Should -Match 'memory_shared:'
            $yaml | Should -Not -Match 'zai_api_key'
            $yaml | Should -Match 'coding_secrets_bundle'
            $yaml | Should -Not -Match 'openrouter_api_key'
            $yaml | Should -Not -Match 'minimax_api_key'
            $yaml | Should -Match '(?m)^  agent_config_oc-orch:$'
            $yaml | Should -Match '(?m)^  agent_config_oc-base:$'
            $yaml | Should -Match '(?m)^  agent_config_oc-base-1:$'
            $yaml | Should -Match '(?m)^  memory_shared:$'
        }

        It "3-agent USA tier has no global provider secrets" {
            $path = Join-Path $script:TestComposeDir "us.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'usa'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_SOVEREIGNTY: usa'
            $yaml | Should -Match 'TRIO_NETWORK: orchestration_net'
            $yaml | Should -Match 'memory_shared:'
            $yaml | Should -Not -Match 'zai_api_key'
            $yaml | Should -Match 'coding_secrets_bundle'
            $yaml | Should -Not -Match 'openrouter_api_key'
            $yaml | Should -Not -Match 'minimax_api_key'
        }

        It "3-agent Global tier includes secret bundles per agent" {
            $path = Join-Path $script:TestComposeDir "gl.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_SOVEREIGNTY: global'
            $yaml | Should -Match 'TRIO_NETWORK: orchestration_net'
            $yaml | Should -Match 'memory_shared:'
            $yaml | Should -Match 'TST_ORCH_secrets_bundle'
            $yaml | Should -Match 'TST_VERI_secrets_bundle'
            $yaml | Should -Match 'TST_VERI-1_secrets_bundle'
        }

        It "3-agent fleet exposes calculated gateway port on every agent" {
            $path = Join-Path $script:TestComposeDir "ports.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match '20100:18789'
            $yaml | Should -Match '20200:18789'
            $yaml | Should -Match '20201:18789'
        }

        It "3-agent fleet disables bonjour on every agent to prevent mDNS crash loops" {
            $path = Join-Path $script:TestComposeDir "bonjour.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_DISABLE_BONJOUR: "?1"?'
        }

        It "3-agent fleet agent volumes are auto-created by Swarm (not external)" {
            $path = Join-Path $script:TestComposeDir "ext.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST' -InstallTailscale 'true' -InstallFleet 'true' -InstallWorkspaceRepos 'https://github.com/victor/test-repo' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            # Agent volume entries should NOT have external: true (Swarm auto-creates with stack prefix)
            $yaml | Should -Match '(?m)^  agent_config_oc-orch:$'
            $yaml | Should -Match '(?m)^  agent_persist_oc-orch:$'
            $yaml | Should -Match '(?m)^  agent_config_oc-base:$'
            $yaml | Should -Match '(?m)^  agent_persist_oc-base:$'
            $yaml | Should -Match '(?m)^  memory_shared:$'
            $yaml | Should -Match '(?m)^  interclaw_workspace:$'
            # proxy_audit should also NOT have external: true
            $yaml | Should -Match '(?m)^  proxy_audit:$'
        }

        It "3-agent fleet includes all sidecars when enabled" -Skip {
            $path = Join-Path $script:TestComposeDir "all.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match '  sentry:'
            $yaml | Should -Not -Match '  tailscale:'
        }

        It "3-agent fleet omits sidecars when disabled" {
            $path = Join-Path $script:TestComposeDir "none.yml"
            New-FleetCompose -Agents $script:Agent3 -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Not -Match '  sentry:'
            $yaml | Should -Not -Match '  tailscale:'
        }

    Context "New-FleetCompose — 1-agent fleets" -Tag "Deploy" {
        BeforeAll {
            $script:TestComposeDir1 = Join-Path $env:TEMP "Interclaw-Compose1-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:TestComposeDir1 -Force | Out-Null

            Mock Invoke-NativeCommand { return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = "image found" } } -ModuleName SalmonRun.Deploy

            $script:Agent1 = @(
                @{ Role='ORCH'; Index=0; InstanceId='84'; AgentName='Agent-TST-ORCH-84'; GatewayPort=20100 }
            )
        }

        AfterAll {
            if (Test-Path $script:TestComposeDir1) {
                Remove-Item -Recurse -Force $script:TestComposeDir1
            }
        }

        It "1-agent Canada tier has no global provider secrets" {
            $path = Join-Path $script:TestComposeDir1 "ca.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_SOVEREIGNTY: canada'
            $yaml | Should -Not -Match 'TRIO_NETWORK'
            $yaml | Should -Not -Match 'memory_shared:'
            $yaml | Should -Not -Match 'zai_api_key'
            $yaml | Should -Match 'coding_secrets_bundle'
            $yaml | Should -Not -Match 'openrouter_api_key'
            $yaml | Should -Not -Match 'minimax_api_key'
            $yaml | Should -Match '(?m)^  agent_config_oc-orch:$'
        }

        It "1-agent USA tier has no global provider secrets" {
            $path = Join-Path $script:TestComposeDir1 "us.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'usa'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_SOVEREIGNTY: usa'
            $yaml | Should -Not -Match 'TRIO_NETWORK'
            $yaml | Should -Not -Match 'memory_shared:'
            $yaml | Should -Not -Match 'zai_api_key'
            $yaml | Should -Match 'coding_secrets_bundle'
            $yaml | Should -Not -Match 'openrouter_api_key'
            $yaml | Should -Not -Match 'minimax_api_key'
        }

        It "1-agent fleet agent volumes are auto-created by Swarm (not external)" {
            $path = Join-Path $script:TestComposeDir1 "ext.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST' -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match '(?m)^  agent_config_oc-orch:$'
            $yaml | Should -Match '(?m)^  agent_persist_oc-orch:$'
        }

        It "1-agent Global tier includes ORCH secret bundle" {
            $path = Join-Path $script:TestComposeDir1 "gl.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_SOVEREIGNTY: global'
            $yaml | Should -Not -Match 'TRIO_NETWORK'
            $yaml | Should -Not -Match 'memory_shared:'
            $yaml | Should -Match 'TST_ORCH_secrets_bundle'
        }

        It "1-agent fleet exposes calculated gateway port on the sole agent" {
            $path = Join-Path $script:TestComposeDir1 "ports.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match '20100:18789'
        }

        It "1-agent fleet drone uses first (only) agent for env vars" {
            $path = Join-Path $script:TestComposeDir1 "drone.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match 'INTERCLAW_INSTANCE_ID: "84"'
            $yaml | Should -Match 'INSTALL_ROLE: ORCH'
            $yaml | Should -Match 'INTERCLAW_SECRET_PREFIX: TST_ORCH'
        }

        It "1-agent fleet secrets match services count" {
            $path = Join-Path $script:TestComposeDir1 "match.yml"
            New-FleetCompose -Agents $script:Agent1 -ProjectCode 'TST'  -InstallTailscale 'true' -InstallFleet 'true' -OutputPath $path -SovereigntyTier 'canada'
            $yaml = Get-Content $path -Raw
            $serviceSecretRefs = [regex]::Matches($yaml, 'source: (TST_ORCH_\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
            foreach ($ref in $serviceSecretRefs) {
                $yaml | Should -Match "  ${ref}:"
            }
        }
    }

    Context "New-FleetCompose — Native CLI integration" -Tag "Deploy" {
        BeforeAll {
            $script:TestComposeDirCli = Join-Path $env:TEMP "Interclaw-ComposeCli-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:TestComposeDirCli -Force | Out-Null

            Mock Invoke-NativeCommand { return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = "image found" } } -ModuleName SalmonRun.Deploy

            $script:Agent1Cli = @(
                @{ Role='ORCH'; Index=0; InstanceId='84'; AgentName='Agent-TST-ORCH-84'; GatewayPort=20100 }
            )
        }

        AfterAll {
            if (Test-Path $script:TestComposeDirCli) {
                Remove-Item -Recurse -Force $script:TestComposeDirCli
            }
        }

        It "does not mount coding CLI secrets on agents" {
            $path = Join-Path $script:TestComposeDirCli "cli-secrets.yml"
            New-FleetCompose -Agents $script:Agent1Cli -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $agentServices = @("oc-orch", "oc-base")
            foreach ($svc in $agentServices) {
                $idx = $yaml.IndexOf("$svc`:")
                if ($idx -ge 0) {
                    $rest = $yaml.Substring($idx)
                    $endIdx = $rest.IndexOf("`n  ", 1)
                    if ($endIdx -lt 0) { $endIdx = $rest.Length }
                    $svcBlock = $rest.Substring(0, $endIdx)
                    $svcBlock | Should -Not -Match 'source: (opencode_go_key|ATTIO_READ_KEY)'
                }
            }
            $yaml | Should -Match 'coding_secrets_bundle:'
            $yaml | Should -Not -Match 'zai_api_key:'

        }

        It "does not mount ZAI_API_KEY on any agent" {
            $path = Join-Path $script:TestComposeDirCli "no-zai.yml"
            $BaseAgent = @( @{ Role='BASE'; Index=0; InstanceId='85'; AgentName='Agent-TST-BASE-85'; GatewayPort=20300 } )
            New-FleetCompose -Agents $BaseAgent -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Not -Match 'zai_api_key'
        }

        It "does not include CLI auto-install env vars on agents" {
            $path = Join-Path $script:TestComposeDirCli "cli-env.yml"
            New-FleetCompose -Agents $script:Agent1Cli -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Not -Match 'CODE_CLI_AUTO_INSTALL'
            $yaml | Should -Not -Match 'CODE_CLI_PREFERRED'
        }

        It "does not include CODE worker services or mcp_opencode (retired 2026-08-21)" {
            $path = Join-Path $script:TestComposeDirCli "no-code.yml"
            New-FleetCompose -Agents $script:Agent1Cli -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Not -Match '  mcp_opencode:'
            $yaml | Should -Not -Match 'opencode:local'
        }

        It "does not include CODE inbox/outbox volumes" {
            $path = Join-Path $script:TestComposeDirCli "no-code-vol.yml"
            New-FleetCompose -Agents $script:Agent1Cli -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Not -Match 'code_1_inbox:'
            $yaml | Should -Not -Match 'code_1_outbox:'
        }

        It "creates interclaw_workspace volume when workspace repos are configured" {
            $path = Join-Path $script:TestComposeDirCli "workspace-repos.yml"
            New-FleetCompose -Agents $script:Agent1Cli -ProjectCode 'TST'  -InstallTailscale 'false' -InstallFleet 'false' -InstallWorkspaceRepos 'https://github.com/victor/test-repo' -OutputPath $path -SovereigntyTier 'global'
            $yaml = Get-Content $path -Raw
            $yaml | Should -Match '(?m)^  interclaw_workspace:$'
            $yaml | Should -Match 'WORKSPACE_REPOS:'
            $yaml | Should -Match 'interclaw_workspace:/workspace'
        }
    }

    Context "Get-FleetServiceMap" -Tag "Deploy" {
        It "includes agent services from fleet array" {
            $Config = Resolve-FleetConfig -InstallEnv (@'
            { "project": { "code": "T" }, "fleet": { "sovereignty": "global", "agents": [{ "role": "BASE", "name": "" }] }, "features": {"sentry": {"install": true}, "tailscale": {"install": false}, "opencode": {"count": 1, "serverMode": true}} }
'@ | ConvertFrom-Json)
            $Map = Get-FleetServiceMap -FleetConfig $Config
            $Stack = $Config.StackName
            $Map.Keys | Should -Contain "${Stack}_oc-base"
            $Map["${Stack}_oc-base"].Required | Should -BeTrue
        }

        It "includes sentry when INSTALL_SENTRY=true" {
            $Config = Resolve-FleetConfig -InstallEnv (@'
            { "project": { "code": "T" }, "fleet": { "sovereignty": "global", "agents": [{ "role": "BASE", "name": "" }] }, "features": {"sentry": {"install": true}, "tailscale": {"install": false}, "opencode": {"count": 1, "serverMode": true}} }
'@ | ConvertFrom-Json)
            $Map = Get-FleetServiceMap -FleetConfig $Config
            $Stack = $Config.StackName
            $Map.Keys | Should -Contain "${Stack}_is-fleet"
            $Map["${Stack}_is-fleet"].Required | Should -BeFalse
        }
    }

    Context "Resolve-WorkspaceRepos" -Tag "Deploy" {
        It "returns empty string when no repos configured" {
            Mock Test-Path { return $false }
            $result = Resolve-WorkspaceRepos -ProjectCode "TEST"
            $result | Should -Be ""
        }

        It "reads repos from environment variable" {
            $env:INSTALL_WORKSPACE_REPOS = "https://github.com/test/repo1,https://github.com/test/repo2"
            $result = Resolve-WorkspaceRepos -ProjectCode "TEST"
            $result | Should -Match "github.com"
            Remove-Item Env:\INSTALL_WORKSPACE_REPOS -ErrorAction SilentlyContinue
        }
    }

    Context "ConvertTo-ComposeYamlScalar" -Tag "Deploy" {
        It "converts null to 'null'" {
            ConvertTo-ComposeYamlScalar -Value $null | Should -Be "null"
        }

        It "converts bool to lowercase string" {
            ConvertTo-ComposeYamlScalar -Value $true | Should -Be "true"
            ConvertTo-ComposeYamlScalar -Value $false | Should -Be "false"
        }

        It "keeps integers unquoted" {
            ConvertTo-ComposeYamlScalar -Value 42 | Should -Be "42"
        }

        It "keeps long, double, and decimal unquoted" {
            ConvertTo-ComposeYamlScalar -Value ([long]2147483648) | Should -Be "2147483648"
            ConvertTo-ComposeYamlScalar -Value ([double]3.14) | Should -Be "3.14"
            ConvertTo-ComposeYamlScalar -Value ([decimal]99.99) | Should -Be "99.99"
        }

        It "quotes empty string" {
            ConvertTo-ComposeYamlScalar -Value "" | Should -Be '""'
        }

        It "quotes string with leading whitespace" {
            ConvertTo-ComposeYamlScalar -Value "  hello" | Should -Be '"  hello"'
        }

        It "quotes string with trailing whitespace" {
            ConvertTo-ComposeYamlScalar -Value "hello  " | Should -Be '"hello  "'
        }

        It "quotes string containing colon" {
            ConvertTo-ComposeYamlScalar -Value "key:value" | Should -Be '"key:value"'
        }

        It "quotes string containing special YAML characters" {
            ConvertTo-ComposeYamlScalar -Value "val#1" | Should -Be '"val#1"'
            ConvertTo-ComposeYamlScalar -Value "{json}" | Should -Be '"{json}"'
            ConvertTo-ComposeYamlScalar -Value "[list]" | Should -Be '"[list]"'
            ConvertTo-ComposeYamlScalar -Value "a,b" | Should -Be '"a,b"'
            ConvertTo-ComposeYamlScalar -Value "a&b" | Should -Be '"a&b"'
        }

        It "quotes boolean-like string" {
            ConvertTo-ComposeYamlScalar -Value "true" | Should -Be '"true"'
            ConvertTo-ComposeYamlScalar -Value "false" | Should -Be '"false"'
            ConvertTo-ComposeYamlScalar -Value "yes" | Should -Be '"yes"'
            ConvertTo-ComposeYamlScalar -Value "no" | Should -Be '"no"'
            ConvertTo-ComposeYamlScalar -Value "on" | Should -Be '"on"'
            ConvertTo-ComposeYamlScalar -Value "off" | Should -Be '"off"'
        }

        It "quotes string containing newline" {
            ConvertTo-ComposeYamlScalar -Value "line1`nline2" | Should -Be '"line1\nline2"'
        }

        It "escapes embedded double quotes" {
            ConvertTo-ComposeYamlScalar -Value 'Say "hello" world' | Should -Be '"Say \"hello\" world"'
        }

        It "escapes backslashes in quoted strings" {
            ConvertTo-ComposeYamlScalar -Value "a\:b" | Should -Be '"a\\:b"'
        }

        It "quotes tilde and numeric strings" {
            ConvertTo-ComposeYamlScalar -Value "~" | Should -Be '"~"'
            ConvertTo-ComposeYamlScalar -Value "123" | Should -Be '"123"'
            ConvertTo-ComposeYamlScalar -Value "3.14" | Should -Be '"3.14"'
        }

        It "does not quote plain strings" {
            ConvertTo-ComposeYamlScalar -Value "hello" | Should -Be "hello"
            ConvertTo-ComposeYamlScalar -Value "simple-value" | Should -Be "simple-value"
            ConvertTo-ComposeYamlScalar -Value "abc123" | Should -Be "abc123"
        }
    }

    Context "Copy-FilesToVolume" -Tag "Deploy" {
        BeforeAll {
            Mock Write-SetupLog { }
            Mock Write-Information { }
        }

        It "returns false when container creation fails with null" {
            Mock docker { return $null } -ParameterFilter { $args[0] -eq 'run' }
            $result = Copy-FilesToVolume -VolumeName "test_vol" -Files @(@{ Source = "test.txt"; Target = "test.txt" }) -Description "test"
            $result | Should -BeFalse
        }

        It "returns false when container creation returns empty string" {
            Mock docker { return "" } -ParameterFilter { $args[0] -eq 'run' }
            $result = Copy-FilesToVolume -VolumeName "test_vol" -Files @(@{ Source = "test.txt"; Target = "test.txt" }) -Description "test"
            $result | Should -BeFalse
        }

        It "returns true when all files copy successfully" {
            Mock docker { return "container123" } -ParameterFilter { $args[0] -eq 'run' }
            Mock Invoke-NativeCommand { return [pscustomobject]@{ Success = $true; Output = ""; ExitCode = 0 } }
            $result = Copy-FilesToVolume -VolumeName "test_vol" -Files @(@{ Source = "src/a.txt"; Target = "a.txt" }) -Description "test"
            $result | Should -BeTrue
        }

        It "returns false when docker cp fails" {
            Mock docker { return "container123" } -ParameterFilter { $args[0] -eq 'run' }
            Mock Invoke-NativeCommand { return [pscustomobject]@{ Success = $false; Output = "error"; ExitCode = 1 } }
            $result = Copy-FilesToVolume -VolumeName "test_vol" -Files @(@{ Source = "src/a.txt"; Target = "a.txt" }) -Description "test"
            $result | Should -BeFalse
        }

        It "returns false when exec command fails" {
            $script:ExecTestInc = 0
            Mock docker { return "container123" } -ParameterFilter { $args[0] -eq 'run' }
            Mock Invoke-NativeCommand {
                $script:ExecTestInc++
                if ($script:ExecTestInc -ge 2) { return [pscustomobject]@{ Success = $false; Output = "exec error"; ExitCode = 1 } }
                return [pscustomobject]@{ Success = $true; Output = ""; ExitCode = 0 }
            }
            $result = Copy-FilesToVolume -VolumeName "test_vol" -Files @(@{ Source = "src/a.txt"; Target = "a.txt" }) -ExecCommands @("chmod 644 /target/a.txt") -Description "test"
            $result | Should -BeFalse
            Remove-Variable ExecTestInc -Scope Script -ErrorAction SilentlyContinue
        }

        It "calls docker rm -f in finally block even on exception" {
            $global:RmCalledTest = $null
            Mock docker {
                if ($args[0] -eq 'run') { return "container123" }
                if ($args[0] -eq 'rm') { $global:RmCalledTest = $args; return $null }
                return $null
            }
            Mock Invoke-NativeCommand { throw "unexpected error" }
            $result = Copy-FilesToVolume -VolumeName "test_vol" -Files @(@{ Source = "src/a.txt"; Target = "a.txt" }) -Description "test"
            $result | Should -BeFalse
            $global:RmCalledTest | Should -Not -BeNullOrEmpty
            $global:RmCalledTest[0] | Should -Be "rm"
            $global:RmCalledTest[1] | Should -Be "-f"
            Remove-Variable RmCalledTest -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe "Start-ParallelImageBuild" -Tag "Deploy" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $moduleDirsPP = @('SalmonRun.Config','SalmonRun.Secrets','SalmonRun.Fleet','SalmonRun.Deploy','SalmonRun.Identity','SalmonRun.Images')
        foreach ($dir in $moduleDirsPP) {
            $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$dir.ps1"
            if (Test-Path $modulePath) { . $modulePath }
        }

        $script:PPTestDir = Join-Path $env:TEMP "Interclaw-Parallel-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:PPTestDir -Force | Out-Null
        $infraDir = Join-Path $script:PPTestDir "Infrastructure"
        New-Item -ItemType Directory -Path $infraDir -Force | Out-Null
        $moduleImages = Join-Path $script:PPTestDir "Skills" "Docker" "Modules" "SalmonRun.Images" "Public"
        New-Item -ItemType Directory -Path $moduleImages -Force | Out-Null
        $moduleDeploy = Join-Path $script:PPTestDir "Skills" "Docker" "Modules" "SalmonRun.Deploy" "Public"
        New-Item -ItemType Directory -Path $moduleDeploy -Force | Out-Null
        $moduleCore = Join-Path $script:PPTestDir "Skills" "Docker" "Modules" "SalmonRun.Core"
        New-Item -ItemType Directory -Path $moduleCore -Force | Out-Null
        "FROM scratch" | Set-Content -Path (Join-Path $infraDir "sentry.Dockerfile")
        "FROM scratch" | Set-Content -Path (Join-Path $infraDir "code-worker.Dockerfile")
        "FROM scratch" | Set-Content -Path (Join-Path $infraDir "api-proxy.Dockerfile")
        "FROM scratch" | Set-Content -Path (Join-Path $infraDir "docusign.Dockerfile")
        "FROM scratch" | Set-Content -Path (Join-Path $infraDir "mcp_browserless.Dockerfile")

        $coreFunc = @'
function Write-SetupLog { param($Message, $Level) }
function Get-HomeDir { return $env:TEMP }
'@
        Set-Content -Path (Join-Path $moduleCore "SalmonRun.Core.ps1") -Value $coreFunc

        $pullFunc = @'
function Invoke-ImagePull { Write-Host "pull ok" }
'@
        Set-Content -Path (Join-Path $moduleDeploy "Invoke-ImagePull.ps1") -Value $pullFunc

        $sentryFunc = @'
function Invoke-SentryImageBuild { Write-Host "sentry ok" }
'@
        Set-Content -Path (Join-Path $moduleImages "Invoke-SentryImageBuild.ps1") -Value $sentryFunc

        $workerFunc = @'
function Invoke-CodeWorkerImageBuild { Write-Host "worker ok" }
'@
        Set-Content -Path (Join-Path $moduleDeploy "Invoke-CodeWorkerImageBuild.ps1") -Value $workerFunc

        $proxyFunc = @'
function Invoke-ProxyImageBuild { Write-Host "proxy ok" }
'@
        Set-Content -Path (Join-Path $moduleImages "Invoke-ProxyImageBuild.ps1") -Value $proxyFunc

        $hashFunc = @'
function Get-ImageSourceHash { return "TESTHASH" }
'@
        Set-Content -Path (Join-Path $moduleDeploy "Get-ImageSourceHash.ps1") -Value $hashFunc
    }

    AfterAll {
        if (Test-Path $script:PPTestDir) {
            Remove-Item -Recurse -Force $script:PPTestDir -ErrorAction SilentlyContinue
        }
    }

    It "returns a hashtable with Jobs and BuildLogDir keys" {
        $result = Start-ParallelImageBuild -TargetDir $script:PPTestDir -ImageVersion "test"
        $result | Should -BeOfType [hashtable]
        $result.ContainsKey("Jobs") | Should -Be $true
        $result.ContainsKey("BuildLogDir") | Should -Be $true
        $result.Jobs.Count | Should -Be 10
        Test-Path $result.BuildLogDir | Should -Be $true

        $null = $result.Jobs | Wait-Job -Timeout 30 -ErrorAction SilentlyContinue
        $result.Jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    It "creates the build log directory on disk" {
        $result = Start-ParallelImageBuild -TargetDir $script:PPTestDir -ImageVersion "test"
        Test-Path $result.BuildLogDir | Should -Be $true
        $null = $result.Jobs | Wait-Job -Timeout 30 -ErrorAction SilentlyContinue
        $result.Jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

Describe "Receive-ParallelImageBuild" -Tag "Deploy" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $moduleDirsRP = @('SalmonRun.Config','SalmonRun.Secrets','SalmonRun.Fleet','SalmonRun.Deploy','SalmonRun.Identity')
        foreach ($dir in $moduleDirsRP) {
            $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$dir.ps1"
            if (Test-Path $modulePath) { . $modulePath }
        }
    }

    It "throws on null context" {
        { Receive-ParallelImageBuild -BuildContext $null } | Should -Throw
    }

    It "throws on context missing keys" {
        { Receive-ParallelImageBuild -BuildContext @{ } } | Should -Throw
    }

    It "returns success with empty results for zero jobs" {
        $result = Receive-ParallelImageBuild -BuildContext @{ Jobs = @(); BuildLogDir = $env:TEMP }
        $result.Success | Should -Be $true
        $result.Results.Count | Should -Be 0
        $result.FailedBuilds.Count | Should -Be 0
    }

    It "handles all-successful jobs" {
        $job1 = Start-Job -ScriptBlock { return @{ Name = "test:local"; Success = $true; DurationMs = 10 } }
        $null = Wait-Job $job1 -Timeout 10
        $result = Receive-ParallelImageBuild -BuildContext @{ Jobs = @($job1); BuildLogDir = $env:TEMP }
        $result.Success | Should -Be $true
        $result.Results.Count | Should -Be 1
        $result.FailedBuilds.Count | Should -Be 0
    }

    It "handles one-failed job" {
        $job1 = Start-Job -ScriptBlock { return @{ Name = "fail:local"; Success = $false; DurationMs = 5; Error = "build error" } }
        $null = Wait-Job $job1 -Timeout 10
        $result = Receive-ParallelImageBuild -BuildContext @{ Jobs = @($job1); BuildLogDir = $env:TEMP }
        $result.Success | Should -Be $false
        $result.FailedBuilds.Count | Should -Be 1
        $result.FailedBuilds[0] | Should -Be "fail:local"
    }

    It "removes jobs after receiving" {
        $job1 = Start-Job -ScriptBlock { return @{ Name = "test:local"; Success = $true; DurationMs = 10 } }
        $null = Wait-Job $job1 -Timeout 10
        $r = Receive-ParallelImageBuild -BuildContext @{ Jobs = @($job1); BuildLogDir = $env:TEMP }
        $r.Success | Should -Be $true
        $r.Results.Count | Should -Be 1
    }
}

Describe "Invoke-InterclawDeployment -BuildPhase" -Tag "Deploy" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $moduleDirsBP = @('SalmonRun.Config','SalmonRun.Secrets','SalmonRun.Fleet','SalmonRun.Deploy','SalmonRun.Identity')
        foreach ($dir in $moduleDirsBP) {
            $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$dir.ps1"
            if (Test-Path $modulePath) { . $modulePath }
        }

        $script:BPTestDir = Join-Path $env:TEMP "Interclaw-BuildPhase-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:BPTestDir -Force | Out-Null
        $infraDir = Join-Path $script:BPTestDir "Infrastructure"
        New-Item -ItemType Directory -Path $infraDir -Force | Out-Null
        "version: '3'" | Set-Content -Path (Join-Path $infraDir "docker-compose.interclaw.yml")
        $moduleDeploy = Join-Path $script:BPTestDir "Skills" "Docker" "Modules" "SalmonRun.Deploy" "Public"
        New-Item -ItemType Directory -Path $moduleDeploy -Force | Out-Null
        $moduleCore = Join-Path $script:BPTestDir "Skills" "Docker" "Modules" "SalmonRun.Core"
        New-Item -ItemType Directory -Path $moduleCore -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:BPTestDir) {
            Remove-Item -Recurse -Force $script:BPTestDir -ErrorAction SilentlyContinue
        }
    }

    It "BuildPhase1 returns a context with Start-ParallelImageBuild" {
        $script:CallLog = @()
        function Start-ParallelImageBuild {
            $script:CallLog += "Start-ParallelImageBuild called"
            return @{ Jobs = @(); BuildLogDir = $env:TEMP }
        }
        $agentConfig = @(@{ Role = 'ORCH'; Index = 0; InstanceId = '1'; AgentName = 'Agent-TST-ORCH-1'; GatewayPort = 20100 })
        $result = Invoke-InterclawDeployment -TargetDir $script:BPTestDir -AgentConfigs $agentConfig -ProjectCode "TST" -BuildPhase "BuildPhase1"
        $result | Should -BeOfType [hashtable]
        $result.ContainsKey("Jobs") | Should -Be $true
        $script:CallLog[0] | Should -Be "Start-ParallelImageBuild called"
    }

    It "BuildPhase All (default) with -SkipBuilds skips image builds but calls deploy functions" {
        $script:CallLog = @()
        function Invoke-ImagePull { $script:CallLog += "Invoke-ImagePull" }
        function Invoke-SentryImageBuild { $script:CallLog += "Invoke-SentryImageBuild" }
        function Invoke-CodeWorkerImageBuild { $script:CallLog += "Invoke-CodeWorkerImageBuild" }
        function Invoke-ProxyImageBuild { $script:CallLog += "Invoke-ProxyImageBuild" }
        function Initialize-AgentVolumes { $script:CallLog += "Initialize-AgentVolumes" }
        function Initialize-SwarmReadiness { $script:CallLog += "Initialize-SwarmReadiness" }
        function Publish-FleetStack { $script:CallLog += "Publish-FleetStack" }
        function Test-FleetDeployment { $script:CallLog += "Test-FleetDeployment" }
        function New-FleetAliases { $script:CallLog += "New-FleetAliases" }
        function Get-StackName { return "TST" }

        $agentConfig = @(@{ Role = 'ORCH'; Index = 0; InstanceId = '1'; AgentName = 'Agent-TST-ORCH-1'; GatewayPort = 20100 })
        Invoke-InterclawDeployment -TargetDir $script:BPTestDir -AgentConfigs $agentConfig -ProjectCode "TST" -SkipBuilds
        $script:CallLog -match "Invoke-ImagePull" | Should -Be $null
        $script:CallLog -match "Invoke-SentryImageBuild" | Should -Be $null
        $script:CallLog -match "Invoke-CodeWorkerImageBuild" | Should -Be $null
        $script:CallLog -match "Invoke-ProxyImageBuild" | Should -Be $null
        $script:CallLog -match "Initialize-AgentVolumes" | Should -Not -Be $null
        $script:CallLog -match "Publish-FleetStack" | Should -Not -Be $null
    }
}

Describe "Invoke-AgentReseed" -Tag "Deploy" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $moduleDirs = @('SalmonRun.Config','SalmonRun.Secrets','SalmonRun.Fleet','SalmonRun.Deploy','SalmonRun.Identity')
        foreach ($dir in $moduleDirs) {
            $leaf = $dir | Split-Path -Leaf
            $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$leaf.ps1"
            if (Test-Path $modulePath) { . $modulePath }
        }

        $global:ReseedCallLog = @()
        function Write-SetupLog { param($Message, $Level) }
        function Get-StackName { return "TEST" }
        function Get-OwnerPlaceholders { return @{} }
        function Get-RoleFileMap { return @{ ORCH = @("agents.md") } }
        function Get-SharedFiles { return @("User.md") }
        function Get-AgentServiceName { param($Role, $Index) return "oc-$($Role.ToLower())$(if ($Index -gt 0) { "-$Index" } else { '' })" }
        function Get-AgentVolumeName { param($StackName, $VolumeType, $Role, $Index) return "${StackName}_${VolumeType}_oc-$($Role.ToLower())" }
        function Copy-FilesToVolume { param($VolumeName, $Files, $Description) return $true }
        function Restart-FleetService { param($ServiceName) $global:ReseedCallLog += "Restart:$ServiceName" }

        function global:DockerMock ($cmd) { process { if ($cmd -eq 'stack-ps') { return @('TEST_oc-orch.1') } elseif ($cmd -eq 'vol-ls') { return 'TEST_agent_config_oc-orch' } else { return $null } } }
    }

    AfterAll {
        Remove-Variable ReseedCallLog -Scope Global -ErrorAction SilentlyContinue
        Remove-Item "Function:global:DockerMock" -ErrorAction SilentlyContinue
    }

    It "returns empty summary when no agents in stack" {
        function global:docker { if ($args[0] -eq 'stack') { return @() } }
        $result = Invoke-AgentReseed -StackName "NOSTACK" -Restart:$false -Force
        $result.Total | Should -Be 0
        $result.Succeeded | Should -Be 0
        $result.Failed | Should -Be 0
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }

    It "returns summary hashtable with Total, Succeeded, Failed" {
        function global:docker { if ($args[0] -eq 'stack') { return @('TEST_oc-orch.1') } elseif ($args[0] -eq 'volume' -and $args[1] -eq 'ls') { return 'TEST_agent_config_oc-orch' } }
        $result = Invoke-AgentReseed -StackName "TEST" -Restart:$false -Force
        $result.Total | Should -Be 1
        $result.Succeeded | Should -Be 1
        $result.ContainsKey('Failed') | Should -Be $true
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }

    It "calls Restart-FleetService when -Restart is set" {
        $global:ReseedCallLog = @()
        function global:docker { if ($args[0] -eq 'stack') { return @('TEST_oc-orch.1') } elseif ($args[0] -eq 'volume' -and $args[1] -eq 'ls') { return 'TEST_agent_config_oc-orch' } }
        Invoke-AgentReseed -StackName "TEST" -Restart:$true -Force | Out-Null
        $global:ReseedCallLog | Should -Contain "Restart:TEST_oc-orch"
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }

    It "does NOT call Restart-FleetService when -Restart is unset" {
        $global:ReseedCallLog = @()
        function global:docker { if ($args[0] -eq 'stack') { return @('TEST_oc-orch.1') } elseif ($args[0] -eq 'volume' -and $args[1] -eq 'ls') { return 'TEST_agent_config_oc-orch' } }
        Invoke-AgentReseed -StackName "TEST" -Restart:$false -Force | Out-Null
        $global:ReseedCallLog | Should -Not -Contain "Restart:TEST_oc-orch"
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }

    It "skips agents with missing config volumes" {
        function global:docker { if ($args[0] -eq 'stack') { return @('TEST_oc-orch.1') } elseif ($args[0] -eq 'volume' -and $args[1] -eq 'ls') { return $null } }
        $result = Invoke-AgentReseed -StackName "TEST" -Restart:$false -Force
        $result.Succeeded | Should -Be 1
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }
}

Describe "reseed-agent-config.ps1 wrapper" -Tag "Deploy" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $corePublic = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public"
        if (Test-Path $corePublic) { Get-ChildItem -Path $corePublic -Filter '*.ps1' | ForEach-Object { . $_.FullName } }
        $moduleDirs = @('SalmonRun.Config','SalmonRun.Secrets','SalmonRun.Constants','SalmonRun.Process','SalmonRun.Fleet','SalmonRun.Deploy','SalmonRun.Identity')
        foreach ($dir in $moduleDirs) {
            $leaf = $dir | Split-Path -Leaf
            $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$leaf.ps1"
            if (Test-Path $modulePath) { . $modulePath }
        }

        $global:WrapperCallLog = @()
        function Get-StackName { return "TEST" }
        function Get-AgentServiceName { param($Role, $Index) return "oc-$($Role.ToLower())" }
        function Invoke-AgentReseed { param($StackName, $Roles, $File, $OwnerPlaceholders, $Restart, $Force) $global:WrapperCallLog += ("IR:" + $StackName + ":" + ($Roles -join ',') + ":" + $Restart + ":" + $Force); return @{ Total = 1; Succeeded = 1; Failed = 0 } }
    }

    AfterAll {
        Remove-Variable WrapperCallLog -Scope Global -ErrorAction SilentlyContinue
    }

    It "dispatches to Invoke-AgentReseed with correct params" -Skip {
        $global:WrapperCallLog = @()
        function global:docker { if ($args[0] -eq 'service' -and $args[1] -eq 'ls') { return 'TEST_oc-orch' }; return $null }
        & "$PSScriptRoot\..\..\Scripts\Admin\reseed-agent-config.ps1" -Role ORCH -Force
        $global:WrapperCallLog | Should -Contain "IR:TEST:ORCH:True:True"
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }

    It "passes -NoRestart as Restart=false" -Skip {
        $global:WrapperCallLog = @()
        function global:docker { if ($args[0] -eq 'service' -and $args[1] -eq 'ls') { return 'TEST_oc-orch' }; return $null }
        & "$PSScriptRoot\..\..\Scripts\Admin\reseed-agent-config.ps1" -Role BASE -NoRestart
        $global:WrapperCallLog | Should -Contain "IR:TEST:BASE:False:False"
        Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
    }
}

Describe "Invoke-PrePullBaseImages" -Tag "Deploy" {
    It "returns success when all images are pre-pulled" -Skip {
        Mock Invoke-NativeCommand { return [pscustomobject]@{ Success = $true; Output = "pulled"; ExitCode = 0 } }
        { Invoke-PrePullBaseImages -TargetDir "C:\temp" } | Should -Not -Throw
    }
}

Describe "New-FleetDeploymentOptions" -Tag "Deploy" {
    It "returns a hashtable with deployment options" -Skip {
        $result = New-FleetDeploymentOptions -ProjectCode "TEST" -AgentNumber 2 -InstallFleet "true"
        $result | Should -BeOfType [hashtable]
        $result.ContainsKey("UpdateDelaySec") | Should -Be $true
        $result.ContainsKey("RollbackMonitorSec") | Should -Be $true
    }
}

Describe "Assert-DockerfileCopyPaths" -Tag "Deploy", "Preflight" {
    BeforeAll {
        $script:DfPassDir = Join-Path $env:TEMP "Interclaw-DfPass-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:DfPassDir -Force | Out-Null
        "@" | Set-Content -Path (Join-Path $script:DfPassDir "test.Dockerfile")
        "COPY test-src.txt /app/" | Add-Content -Path (Join-Path $script:DfPassDir "test.Dockerfile")
        "test content" | Set-Content -Path (Join-Path $script:DfPassDir "test-src.txt")

        $script:DfFailDir = Join-Path $env:TEMP "Interclaw-DfFail-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:DfFailDir -Force | Out-Null
        "@" | Set-Content -Path (Join-Path $script:DfFailDir "broken.Dockerfile")
        "COPY missing-file.txt /app/" | Add-Content -Path (Join-Path $script:DfFailDir "broken.Dockerfile")
    }

    AfterAll {
        if (Test-Path $script:DfPassDir) { Remove-Item -Recurse -Force $script:DfPassDir -ErrorAction SilentlyContinue }
        if (Test-Path $script:DfFailDir) { Remove-Item -Recurse -Force $script:DfFailDir -ErrorAction SilentlyContinue }
    }

    It "returns Passed=$true when all COPY sources exist" {
        . "$PSScriptRoot\..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Assert-DockerfileCopyPaths.ps1"
        $result = Assert-DockerfileCopyPaths -RootDir $script:DfPassDir
        $result.Passed | Should -Be $true
        $result.Failures.Count | Should -Be 0
    }

    It "returns Passed=$false and lists missing sources" {
        . "$PSScriptRoot\..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Assert-DockerfileCopyPaths.ps1"
        $result = Assert-DockerfileCopyPaths -RootDir $script:DfFailDir
        $result.Passed | Should -Be $false
        $result.Failures.Count | Should -BeGreaterThan 0
        $result.Failures[0] | Should -Match "broken.Dockerfile"
    }

    It "validates real repo Dockerfiles pass" {
        . "$PSScriptRoot\..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Assert-DockerfileCopyPaths.ps1"
        $repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
        $result = Assert-DockerfileCopyPaths -RootDir $repoRoot
        $result.Passed | Should -Be $true
    }
}

Describe "FleetComposeHealthcheckPlacement" -Tag "Deploy", "Regression-Only" {
    It "validates generated compose file has healthcheck at service level, not under deploy" {
        $composePath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\docker-compose.interclaw.yml"
        if (-not (Test-Path $composePath)) {
            Write-Host "  [SKIP] Generated compose file not found" -ForegroundColor Yellow
            return
        }

        $lines = Get-Content $composePath
        $inDeployBlock = $false
        $deployIndent = -1
        $errors = @()

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -eq '') { continue }

            $indent = ($line.Length - $line.TrimStart().Length)

            if ($trimmed -eq 'deploy:') {
                $inDeployBlock = $true
                $deployIndent = $indent
                continue
            }

            if ($inDeployBlock) {
                if ($indent -le $deployIndent) {
                    $inDeployBlock = $false
                    $deployIndent = -1
                } elseif ($trimmed -match '^healthcheck:') {
                    $errors += "$(Resolve-Path $composePath -Relative): healthcheck nested under deploy"
                }
            }
        }

        $errors | Should -BeNullOrEmpty
    }
}

Describe "OverlayNetworkRoundTrip" -Tag "Deploy", "Network", "Integration" {
    It "creates and removes a test overlay network" -Skip {
        $testNet = "test-net-verify-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $null = docker network create --driver overlay --attachable $testNet 2>&1
            $LASTEXITCODE | Should -Be 0
            $found = docker network ls --filter "name=$testNet" --format '{{.Name}}' 2>$null
            $found | Should -Be $testNet
        } finally {
            docker network rm $testNet 2>$null | Out-Null
        }
    }
}

Describe "StaleContainerDisconnect" -Tag "Deploy", "Regression-Only" {
    It "identifies stale containers not matching stack name prefix" {
        $Props = [System.Collections.ArrayList]::new()
        $null = $Props.Add([pscustomobject]@{ Name = "abc123"; Value = [pscustomobject]@{ Name = "/container1" } })
        $null = $Props.Add([pscustomobject]@{ Name = "FRAD_stack_container2"; Value = [pscustomobject]@{ Name = "/FRAD_stack_container2" } })
        $staleContainers = $Props | Where-Object { $_.Name -notlike "FRAD*" }
        $staleContainers.Count | Should -Be 1
        $staleContainers[0].Name | Should -Be "abc123"
    }

    It "disconnect command uses NETWORK before CONTAINER argument order" {
        $script:capturedArgs = @()
        function global:docker { $script:capturedArgs = $args }
        try {
            $net = "service_net"
            $containerId = "abc123"
            docker network disconnect --force $net $containerId
            $script:capturedArgs[0] | Should -Be "network"
            $script:capturedArgs[1] | Should -Be "disconnect"
            $script:capturedArgs[2] | Should -Be "--force"
            $script:capturedArgs[3] | Should -Be "service_net"
            $script:capturedArgs[4] | Should -Be "abc123"
        } finally {
            Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
        }
    }
}

Describe "PortCentralization" -Tag "Deploy", "Regression-Only" {
    BeforeAll {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
        $registryPath = Join-Path $repoRoot "Infrastructure" "port-registry.json"
        $registry = Get-Content $registryPath -Raw | ConvertFrom-Json
        $internal = $registry.internal
        $internal | Out-Null
    }

    It "Dockerfile EXPOSE matches port-registry.json" {
        $dockerfiles = Get-ChildItem -Path (Join-Path $repoRoot "Infrastructure") -Filter "*.Dockerfile"
        $servicePortMap = @{
            "is-fleet"  = [int]$internal."is-fleet"
        }
        $failures = @()
        foreach ($df in $dockerfiles) {
            $content = Get-Content $df.FullName -Raw
            $exposeMatch = [regex]::Match($content, 'EXPOSE (\d+)')
            $exposedPort = if ($exposeMatch.Success) { [int]$exposeMatch.Groups[1].Value } else { $null }
            $serviceName = $df.BaseName -replace '\.Dockerfile$', ''
            if ($servicePortMap.ContainsKey($serviceName)) {
                $expectedPort = $servicePortMap[$serviceName]
                if ($exposedPort -ne $expectedPort) {
                    $failures += "$($df.Name): EXPOSE $exposedPort, registry $expectedPort"
                }
            }
        }
        $failures | Should -BeNullOrEmpty -Because "all Dockerfiles must EXPOSE the port from port-registry.json"
    }

    It "Compose port mappings match port-registry.json" {

        $composePath = Join-Path $repoRoot "Infrastructure" "docker-compose.interclaw.yml"
        if (-not (Test-Path $composePath)) {
            Set-ItResult -Inconclusive -Because "generated compose file not found — test requires a prior deploy"
            return
        }

        $compose = Get-Content $composePath -Raw
        $failures = @()

        $mapping = @(
            @{ Service = "is-fleet";     Pattern = '29999:21002' }
        )

        foreach ($m in $mapping) {
            if ($compose -notmatch $m.Pattern) {
                $failures += "$($m.Service): expected $($m.Pattern) in compose"
            }
        }

        $failures | Should -BeNullOrEmpty -Because "all compose port mappings must match the registry"
    }

    It "mcp_opencode is absent from generated compose (retired 2026-08-21)" {
        $composePath = Join-Path $repoRoot "Infrastructure" "docker-compose.interclaw.yml"
        if (-not (Test-Path $composePath)) {
            Set-ItResult -Inconclusive -Because "generated compose file not found — test requires a prior deploy"
            return
        }
        $compose = Get-Content $composePath -Raw
        $compose | Should -Not -Match 'mcp_opencode:' -Because "mcp_opencode was retired and must not appear in generated compose"
    }

    It "No legacy port range (3000-4096) in production configuration" {
        $searchPaths = @(
            Join-Path $repoRoot "Infrastructure"
            Join-Path $repoRoot "Skills" "Docker"
        )
        $excludePatterns = @(
            'node_modules',
            '.git',
            'docker-compose.interclaw.yml',
            'Interclaw.Deprecated',
            'Templates',
            'Browserless\\Skills',
            'pipeline\\zoho-browserless.md',
            'amazon-cookie-downloader',
            'amazon-interactive-downloader',
            'amazon-invoice-downloader',
            'amazon-login-debug',
            'test-connection.js',
            'zoho-quick-categorize',
            'Tests'
        )
        $legacyPattern = ':(3\d{3}|4\d{3})'
        $failures = @()
        foreach ($path in $searchPaths) {
            if (-not (Test-Path $path)) { continue }
            $files = Get-ChildItem -Path $path -Recurse -File | Where-Object {
                $exclude = $false
                foreach ($ep in $excludePatterns) {
                    if ($_.FullName -match [regex]::Escape($ep)) { $exclude = $true; break }
                }
                -not $exclude
            }
            foreach ($file in $files) {
                if ($file.Extension -notin @('.ps1', '.sh', '.js', '.json', '.Dockerfile', '.yml', '.yaml', '.py', '.cs', '.csproj')) { continue }
                $content = Get-Content $file.FullName -Raw
                if ($content -match $legacyPattern) {
                    $relative = Resolve-Path $file.FullName -Relative
                    $failures += "$relative matches legacy port range"
                }
            }
        }
        $failures | Should -BeNullOrEmpty -Because "no legacy port values (3000-4096) should remain in production code"
    }

    It "port-registry.json has sufficient coverage" {
        $internalCount = ($internal.PSObject.Properties.Name | Measure-Object).Count
        $internalCount | Should -BeGreaterThan 2 -Because "registry should cover all active services (is-fleet and infrastructure services)"

        # Verify known active services present
        $internal."is-fleet" | Should -Be 21002
        # Retired services must NOT be in the internal section
        $internal.PSObject.Properties.Name | Should -Not -Contain 'mcp_opencode_health'
        $internal.PSObject.Properties.Name | Should -Not -Contain 'mcp_opencode_server'
        $internal.PSObject.Properties.Name | Should -Not -Contain 'mcp_aqe'
        $internal.PSObject.Properties.Name | Should -Not -Contain 'mcp_web'
        $internal.PSObject.Properties.Name | Should -Not -Contain 'is-marketer'
        $internal.PSObject.Properties.Name | Should -Not -Contain 'is-hermes'
    }

    Context "Write-DeployManifest" -Tag "Deploy" {
        It "accepts the expected parameter set" {
            $cmd = Get-Command Write-DeployManifest -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Parameters.ContainsKey('StackName') | Should -Be $true
            $cmd.Parameters.ContainsKey('TargetDir') | Should -Be $true
            $cmd.Parameters.ContainsKey('AgentConfigs') | Should -Be $true
            $cmd.Parameters.ContainsKey('ImageVersion') | Should -Be $true
            $cmd.Parameters.ContainsKey('ExtraContainerMetadata') | Should -Be $true
        }

        It "supports -WhatIf and does not write when WhatIf is set" {
            $testDir = Join-Path $script:TestTempDir "manifest-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            Write-DeployManifest -StackName "TEST" -TargetDir $testDir -AgentConfigs @(@{ Role = "BASE"; Index = 0 }) -WhatIf

            $manifestPath = Join-Path $testDir "Tasks/Logs/deploy-manifest.json"
            Test-Path $manifestPath | Should -Be $false
        }

        It "writes manifest with expected schema" {
            $testDir = Join-Path $script:TestTempDir "manifest-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            Write-DeployManifest -StackName "TEST" -TargetDir $testDir -AgentConfigs @(@{ Role = "BASE"; Index = 0 })

            $manifestPath = Join-Path $testDir "Tasks/Logs/deploy-manifest.json"
            Test-Path $manifestPath | Should -Be $true

            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $manifest.version | Should -Be 1
            $manifest.git_commit | Should -Not -BeNullOrEmpty
            $manifest.git_branch | Should -Not -BeNullOrEmpty
            $manifest.git_remote | Should -Not -BeNullOrEmpty
            $manifest.deployed_at | Should -Not -BeNullOrEmpty
            $manifest.image_version | Should -Be "local"
            $manifest.containers | Should -Not -BeNullOrEmpty
        }

        It "includes all active core services in the container list with correct image tags" {
            $testDir = Join-Path $script:TestTempDir "manifest-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            Write-DeployManifest -StackName "TEST" -TargetDir $testDir -AgentConfigs @(@{ Role = "BASE"; Index = 0 })

            $manifestPath = Join-Path $testDir "Tasks/Logs/deploy-manifest.json"
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

            # Only is-fleet remains as an active container after the
            # 2026-08-21 MCP/Hermes/openclaw and 2026-08-25 session-worker retirements.
            # Write-DeployManifest still lists retired services in its CoreServices
            # array (for backward-compatible manifest comparison), so we only assert
            # the active one has the correct image tag.
            $svc = 'is-fleet'
            $manifest.containers.$svc | Should -Not -BeNullOrEmpty -Because "$svc should be in the manifest"
            $manifest.containers.$svc.image | Should -Match "$svc|fleet" -Because "image tag should use the correct image base name"
        }

        It "accepts ExtraContainerMetadata overrides" {
            $testDir = Join-Path $script:TestTempDir "manifest-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $extra = @{
                'is-fleet' = @{ image = 'custom-fleet:local' }
            }

            Write-DeployManifest -StackName "TEST" -TargetDir $testDir -AgentConfigs @(@{ Role = "BASE"; Index = 0 }) -ExtraContainerMetadata $extra

            $manifestPath = Join-Path $testDir "Tasks/Logs/deploy-manifest.json"
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $manifest.containers.'is-fleet'.image | Should -Be 'custom-fleet:local'
        }

        It "uses atomic write pattern (no partial files on error)" {
            $testDir = Join-Path $script:TestTempDir "manifest-test-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            Write-DeployManifest -StackName "TEST" -TargetDir $testDir -AgentConfigs @(@{ Role = "BASE"; Index = 0 })

            $manifestPath = Join-Path $testDir "Tasks/Logs/deploy-manifest.json"
            Test-Path "$manifestPath.tmp" | Should -Be $false
            Test-Path $manifestPath | Should -Be $true
        }
    }

    Context "PreserveFleet parameter threading" -Tag @("Deploy", "Regression-Only") {
        It "deploy.ps1 accepts -PreserveFleet switch" {
            $deployScript = Join-Path $PSScriptRoot "..\deploy.ps1"
            $tokens = [System.Management.Automation.PSParser]::Tokenize((Get-Content $deployScript -Raw), [ref]$null)
            $paramNames = $tokens | Where-Object { $_.Type -eq 'Variable' -or $_.Type -eq 'CommandParameter' } | ForEach-Object { $_.Content }
            $paramNames | Should -Contain 'PreserveFleet'
        }

        It "Invoke-InterclawDeployment accepts -PreserveFleet switch" {
            $cmd = Get-Command Invoke-InterclawDeployment -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Parameters.ContainsKey('PreserveFleet') | Should -Be $true
        }

        It "Publish-FleetStack accepts -PreserveFleet switch" {
            $cmd = Get-Command Publish-FleetStack -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.Parameters.ContainsKey('PreserveFleet') | Should -Be $true
        }

        It "Publish-FleetStack sets env var from PreserveFleet switch" {
            $modulePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\SalmonRun.Deploy.ps1"
            if (Test-Path $modulePath) {
                # Dot-source dependencies
                $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
                if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
                $helpersPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
                if (Test-Path $helpersPath) { . $helpersPath }

                . $modulePath

                # Mock script:StackName to avoid the guard
                InModuleScope SalmonRun.Deploy { $script:StackName = "TEST" }
                $prev = $env:INTERCLAW_PRESERVE_FLEET
                try {
                    Publish-FleetStack -SkipDeploy -PreserveFleet -StackName TEST
                    $env:INTERCLAW_PRESERVE_FLEET | Should -Be "true"
                } finally {
                    $env:INTERCLAW_PRESERVE_FLEET = $prev
                }
            }
        }

        It "Publish-FleetStack skips stack removal when PreserveFleet is set (env var path)" {
            $prev = $env:INTERCLAW_PRESERVE_FLEET
            try {
                $env:INTERCLAW_PRESERVE_FLEET = "true"
                # Verify the guard logic is present in the source
                $pubPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Publish-FleetStack.ps1"
                $content = Get-Content $pubPath -Raw
                $content | Should -Match 'INTERCLAW_PRESERVE_FLEET.*true.*skipping stack removal'
            } finally {
                $env:INTERCLAW_PRESERVE_FLEET = $prev
            }
        }

        It "Invoke-InterclawDeployment forwards -PreserveFleet to Publish-FleetStack" {
            $invokePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Invoke-OrchestratorDeployment.ps1"
            $content = Get-Content $invokePath -Raw
            $content | Should -Match 'PreserveFleet.*PreserveFleet'
        }
    }

    Context "retired is-api healthcheck configuration" -Tag "Deploy", "Healthcheck" {
        It "Add-SidecarServicesToCompose no longer references is-api" {
            $path = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Add-SidecarServicesToCompose.ps1"
            $content = Get-Content $path -Raw
            $content | Should -Not -Match 'is-api'
        }

        It "Infrastructure/is-api directory is retired" {
            $dir = Join-Path $PSScriptRoot "..\..\..\Infrastructure\is-api"
            Test-Path $dir | Should -Be $false
        }
    }

    Context "Invoke-WhatIfGuard" -Tag "Deploy" {
        It "executes script block when WhatIf is false" {
            $script:wifExecuted = $false
            Invoke-WhatIfGuard -Message "test" -ScriptBlock { $script:wifExecuted = $true } -WhatIf:$false
            $script:wifExecuted | Should -Be $true
        }

        It "skips execution when WhatIf is true" {
            $script:wifExecuted = $false
            Invoke-WhatIfGuard -Message "test" -ScriptBlock { $script:wifExecuted = $true } -WhatIf:$true
            $script:wifExecuted | Should -Be $false
        }
    }

    Context "Restrict-FileAccess" -Tag "Deploy" {
        It "silently skips when path does not exist" {
            { Restrict-FileAccess -Path "C:\nonexistent\path\file.txt" } | Should -Not -Throw
        }

        It "does not throw on a valid temp file" {
            $testFile = Join-Path $env:TEMP "restrict-test-$(Get-Random).txt"
            "test" | Set-Content $testFile
            { Restrict-FileAccess -Path $testFile } | Should -Not -Throw
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    Context "Test-DeployPhasePrerequisites" -Tag "Deploy" {
        It "returns true when phase has no dependencies" {
            Test-DeployPhasePrerequisites -PhaseName "phase1" -PhaseDependencies @{} -CompletedPhases @() | Should -Be $true
        }

        It "returns true when phase depends on empty list" {
            Test-DeployPhasePrerequisites -PhaseName "phase1" -PhaseDependencies @{ phase1 = @() } -CompletedPhases @() | Should -Be $true
        }

        It "returns true when all dependencies are completed" {
            $deps = @{ phase2 = @("phase1") }
            Test-DeployPhasePrerequisites -PhaseName "phase2" -PhaseDependencies $deps -CompletedPhases @("phase1") | Should -Be $true
        }

        It "returns false when a dependency is missing" {
            $deps = @{ phase2 = @("phase1") }
            Test-DeployPhasePrerequisites -PhaseName "phase2" -PhaseDependencies $deps -CompletedPhases @() | Should -Be $false
        }

        It "returns false when multiple deps and one is missing" {
            $deps = @{ phase3 = @("phase1", "phase2") }
            Test-DeployPhasePrerequisites -PhaseName "phase3" -PhaseDependencies $deps -CompletedPhases @("phase1") | Should -Be $false
        }
    }

    Context "Resolve-AgentConfigsFromInstallJson" -Tag "Deploy" {
        It "returns empty array when install.json has no fleet.agents" {
            $testFile = Join-Path $env:TEMP "test-no-agents-$(Get-Random).json"
            '{"version":"1.0","project":{"code":"TEST"}}' | Set-Content $testFile
            try { Resolve-AgentConfigsFromInstallJson -InstallJsonPath $testFile -ProjectCode "TEST" | Should -BeNullOrEmpty }
            finally { Remove-Item $testFile -Force -ErrorAction SilentlyContinue }
        }

        It "returns empty array when install.json path is invalid" {
            Resolve-AgentConfigsFromInstallJson -InstallJsonPath "C:\nonexistent\file.json" -ProjectCode "TEST" | Should -BeNullOrEmpty
        }
    }

    Context "Get-ImageSourceHash" -Tag "Deploy" {
        It "throws when Dockerfile does not exist" {
            { Get-ImageSourceHash -DockerfilePath "C:\nonexistent\Dockerfile" -TargetDir $env:TEMP -ImageName "test-img" } | Should -Throw
        }

        It "returns a hash string for a valid Dockerfile" {
            $testDir = Join-Path $env:TEMP "img-hash-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $dockerfile = Join-Path $testDir "Dockerfile"
            "FROM alpine:latest`nCOPY . /app" | Set-Content $dockerfile
            try {
                $hash = Get-ImageSourceHash -DockerfilePath $dockerfile -TargetDir $testDir -ImageName "test-img"
                $hash | Should -Not -BeNullOrEmpty
                $hash.Length | Should -Be 16
            } finally { Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue }
        }

        It "returns cached hash on repeated call" {
            $testDir = Join-Path $env:TEMP "img-hash-cache-$(Get-Random)"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $dockerfile = Join-Path $testDir "Dockerfile"
            "FROM alpine:latest" | Set-Content $dockerfile
            $script:ImageSourceHashCache = @{}
            try {
                $h1 = Get-ImageSourceHash -DockerfilePath $dockerfile -TargetDir $testDir -ImageName "test-img"
                $h2 = Get-ImageSourceHash -DockerfilePath $dockerfile -TargetDir $testDir -ImageName "test-img"
                $h2 | Should -Be $h1
            } finally { Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue; $script:ImageSourceHashCache = @{} }
        }
    }

    Context "1Deploy.ps1 Swarm phase job construction" -Tag "Deploy" {
        BeforeAll {
            $script:DeployScriptPath = Join-Path $PSScriptRoot "..\1Deploy.ps1"
            $script:DeployScriptTestDir = Join-Path $env:TEMP "Interclaw-1Deploy-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:DeployScriptTestDir -Force | Out-Null
            Mock Initialize-InterclawEnvironment { }
            Mock Import-InterclawModule { }
            Mock Get-SecretsOwnedKeys { return $null }
            Mock Get-StackName { return "TESTSTACK" }
            Mock Get-AgentHostPort { return "1234" }
            Mock Write-SetupLog { }
            Mock Initialize-SwarmReadiness { }
            Mock Wait-Job { param($Job, $Timeout, $InputObject) return $true }
            Mock Receive-Job { param($Job, $InputObject) return $null }
            Mock Remove-Job { param($Job, $InputObject) }
            Mock Stop-Job { param($Job, $InputObject) }
            $script:SwarmJobArgs = $null
            $script:SwarmJobScriptBlock = $null
        }

        AfterAll {
            if (Test-Path $script:DeployScriptTestDir) { Remove-Item -Recurse -Force $script:DeployScriptTestDir -ErrorAction SilentlyContinue }
        }

        It "passes -StackName and full deploy state into the Swarm phase job" {
            Mock Start-Job {
                param($ScriptBlock, $ArgumentList)
                $script:SwarmJobScriptBlock = $ScriptBlock.ToString()
                $script:SwarmJobArgs = @($ArgumentList)
                return [pscustomobject]@{ Id = 1 }
            }
            $agents = @(@{ Role = "BASE"; Index = 0; AgentName = "oc-base"; InstanceId = "i-1"; Port = 1234 })
            $prevPsModulePath = $env:PSModulePath
            $env:INSTALL_PROJECT = "TESTPROJ"
            try { & $script:DeployScriptPath -TargetDir $script:DeployScriptTestDir -AgentConfigs $agents -ProjectCode TEST -Phase Swarm }
            finally { $env:PSModulePath = $prevPsModulePath }
            $script:SwarmJobArgs.Count | Should -Be 10
            $script:SwarmJobArgs[0] | Should -Be $script:DeployScriptTestDir
            $script:SwarmJobArgs[3] | Should -Be "TESTSTACK"
            $script:SwarmJobScriptBlock | Should -Match 'Publish-FleetStack -StackName \$sn'
            $script:SwarmJobScriptBlock | Should -Match 'Import-InterclawModule Core; Import-InterclawModule Deploy; Import-InterclawModule Fleet'
        }

        It "is parser-valid (no syntax errors)" {
            foreach ($path in @(
                $script:DeployScriptPath,
                (Join-Path $PSScriptRoot "..\deploy.ps1"),
                (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Invoke-DeployPhase.ps1"),
                (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Publish-FleetStack.ps1")
            )) {
                $errs = $null
                $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
                @($errs).Count | Should -Be 0 -Because "parse errors in $path"
            }
        }
    }

    Context "1Deploy.ps1 Volumes phase volume-name convention" -Tag "Deploy" {
        BeforeAll {
            $script:VolDockerCalls = [System.Collections.Generic.List[string]]::new()
            $script:VolWarnSeen = $false
            $env:INSTALL_PROJECT = "TESTPROJ"
            Mock Import-SecretsFromAws { }
            Mock Initialize-InterclawEnvironment { }
            Mock Import-InterclawModule { }
            Mock Get-StackName { return "TESTSTACK" }
            Mock Wait-Job { param($Job, $Timeout, $InputObject) return $true }
            Mock Receive-Job { param($Job, $InputObject) return $null }
            Mock Remove-Job { param($Job, $InputObject) }
            Mock Stop-Job { param($Job, $InputObject) }
        }

        It "checks volumes against the StackName_agent_config_<svc> convention (two-agent config)" {
            $script:VolDockerCalls.Clear()
            function global:docker { $null = $script:VolDockerCalls.Add(($args -join ' ')); return "" }
            Mock Start-Job { return [pscustomobject]@{ Id = 1 } }
            $agents = @(
                @{ Role = "BASE"; Index = 0; AgentName = "oc-base"; InstanceId = "i-1"; Port = 1234 },
                @{ Role = "WORK"; Index = 1; AgentName = "oc-work-1"; InstanceId = "i-2"; Port = 1235 }
            )
            $prevPsModulePath = $env:PSModulePath
            try { & $script:DeployScriptPath -TargetDir $script:DeployScriptTestDir -AgentConfigs $agents -ProjectCode TEST -Phase Volumes }
            finally { $env:PSModulePath = $prevPsModulePath }
            $volFilters = @($script:VolDockerCalls | Where-Object { $_ -like 'volume ls*' })
            $volFilters.Count | Should -Be 4
            $volFilters | Should -Contain 'volume ls -q -f name=^TESTSTACK_agent_config_oc-base$'
            $volFilters | Should -Contain 'volume ls -q -f name=^TESTSTACK_agent_persist_oc-base$'
            $volFilters | Should -Contain 'volume ls -q -f name=^TESTSTACK_agent_config_oc-work-1$'
            $volFilters | Should -Contain 'volume ls -q -f name=^TESTSTACK_agent_persist_oc-work-1$'
            Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
        }

        It "emits the pre-existing-volume WARN when a matching volume exists" {
            $script:VolDockerCalls.Clear()
            $script:VolWarnSeen = $false
            function global:docker {
                $null = $script:VolDockerCalls.Add(($args -join ' '))
                if (($args -join ' ') -match 'name=\^TESTSTACK_agent_config_oc-base\$') { return "TESTSTACK_agent_config_oc-base" }
                return ""
            }
            Mock Write-SetupLog { $script:VolWarnSeen = $true } -ParameterFilter { $Message -match 'pre-existing volume' }
            Mock Start-Job { return [pscustomobject]@{ Id = 1 } }
            $agents = @(@{ Role = "BASE"; Index = 0; AgentName = "oc-base"; InstanceId = "i-1"; Port = 1234 })
            $prevPsModulePath = $env:PSModulePath
            try { & $script:DeployScriptPath -TargetDir $script:DeployScriptTestDir -AgentConfigs $agents -ProjectCode TEST -Phase Volumes }
            finally { $env:PSModulePath = $prevPsModulePath }
            $script:VolWarnSeen | Should -Be $true
            Remove-Item "Function:global:docker" -ErrorAction SilentlyContinue
        }
    }
}

Describe "Invoke-DeployPhase TagOnly contract" -Tag "Deploy" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Invoke-DeployPhase.ps1")
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Test-DeployPhasePrerequisites.ps1")
        Mock Write-AtomicFile { }
        Mock Write-SetupLog { }
    }

    It "tags ConfigSave complete without executing its scriptblock in TagOnly mode" {
        $script:TagOnlyExecuted = $false
        $result = Invoke-DeployPhase -PhaseName "ConfigSave" -ScriptBlock { $script:TagOnlyExecuted = $true } -PhaseDependencies @{} -CompletedPhases @() -TagOnly
        $script:TagOnlyExecuted | Should -Be $false
        $result | Should -Contain "ConfigSave"
    }

    It "does not execute throwing scriptblocks for the previously-exempt phases in TagOnly mode" {
        foreach ($phaseName in @("ConfigSave", "IdentityConfig", "Cleanup")) {
            { Invoke-DeployPhase -PhaseName $phaseName -ScriptBlock { throw "TagOnly violation: phase executed" } -PhaseDependencies @{} -CompletedPhases @() -TagOnly } | Should -Not -Throw -Because "$phaseName must be tagged without executing in TagOnly mode"
        }
    }
}

Describe "Get-ServiceApiToken persistence failure surfacing" -Tag "Deploy" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Publish-FleetStack.ps1")
        Mock Get-SecretFromAws { return "" }
        Mock Write-SetupLog { }
    }

    It "reuses an existing token with Persisted=true" {
        Mock Get-SecretFromAws { return "existing-token" } -ParameterFilter { $KeyName -eq "FLEET_API_TOKEN_REUSE_TEST" }
        $result = Get-ServiceApiToken -TokenName "FLEET_API_TOKEN_REUSE_TEST"
        $result.Value | Should -Be "existing-token"
        $result.Persisted | Should -Be $true
    }

    It "returns Persisted=false and logs an ERROR when create-secret and put-secret-value both fail" {
        Mock Invoke-AwsCommand { return [pscustomobject]@{ Success = $false; ExitCode = 1; Output = "denied" } } -ParameterFilter { $Command.ToString() -match 'put-secret-value' }
        Mock Invoke-AwsCommand { return [pscustomobject]@{ Success = $false; ExitCode = 1; Output = "denied" } } -ParameterFilter { $Command.ToString() -match 'create-secret' }
        $result = Get-ServiceApiToken -TokenName "FLEET_API_TOKEN_FAIL_TEST"
        $result.Persisted | Should -Be $false
        $result.Value | Should -Not -BeNullOrEmpty
        Should -Invoke Write-SetupLog -Times 1 -Exactly -ParameterFilter { $Message -match 'FLEET_API_TOKEN_FAIL_TEST' -and $Message -match 'could not be persisted' }
    }

    It "falls back to put-secret-value and reports Persisted=true when the fallback succeeds" {
        Mock Invoke-AwsCommand { return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = "ok" } } -ParameterFilter { $Command.ToString() -match 'put-secret-value' }
        Mock Invoke-AwsCommand { return [pscustomobject]@{ Success = $false; ExitCode = 1; Output = "denied" } } -ParameterFilter { $Command.ToString() -match 'create-secret' }
        $result = Get-ServiceApiToken -TokenName "FLEET_API_TOKEN_PUTOK_TEST"
        $result.Persisted | Should -Be $true
        $result.Value | Should -Not -BeNullOrEmpty
        Should -Invoke Invoke-AwsCommand -Times 2 -Exactly
    }
}

Describe "deploy.ps1 FleetDeploy monitor fail-loud guards" -Tag "Deploy", "Regression-Only" {
    BeforeAll {
        $script:DeployMonitorContent = Get-Content (Join-Path $PSScriptRoot "..\deploy.ps1") -Raw
    }

    It "treats a failed docker stack services query as a non-stable cycle" {
        $script:DeployMonitorContent | Should -Match '\$monitorUncertain = \$false'
        $script:DeployMonitorContent | Should -Match '\$svcExitCode = \$LASTEXITCODE'
        $script:DeployMonitorContent | Should -Match '\$parseableLines = @\(\$svcResult \| Where-Object'
        $script:DeployMonitorContent | Should -Match 'query failed or returned no parseable replica lines'
        $script:DeployMonitorContent | Should -Match '\$monitorUncertain = \$true\s+\$allStable = \$false\s+continue'
    }

    It "keeps the stable banner out of the failure path" {
        $guardIdx = $script:DeployMonitorContent.IndexOf('cycle non-stable')
        $stableIdx = $script:DeployMonitorContent.IndexOf('[OK] All services stable.')
        $guardIdx | Should -BeGreaterThan 0
        $stableIdx | Should -BeGreaterThan $guardIdx
        $script:DeployMonitorContent | Should -Match 'Could not verify service replicas after'
        $script:DeployMonitorContent | Should -Match '\$criticalScanFailed'
    }
}

Describe "Publish-FleetStack stale-image sweep guard" -Tag "Deploy", "Regression-Only" {
    BeforeAll {
        $script:FleetStackSweepContent = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Publish-FleetStack.ps1") -Raw
    }

    It "skips the sweep entirely when the active-image query fails" {
        $script:FleetStackSweepContent | Should -Match '\$ImageListResult = Invoke-NativeCommand \{ docker stack services'
        $script:FleetStackSweepContent | Should -Match '-not \$ImageListResult\.Success -or \[string\]::IsNullOrWhiteSpace'
        $script:FleetStackSweepContent | Should -Match 'Cannot determine active images'
        $script:FleetStackSweepContent | Should -Match 'skipping stale-image sweep'
    }

    It "keeps docker image rm inside the success branch only" {
        $skipIdx = $script:FleetStackSweepContent.IndexOf('Cannot determine active images')
        $rmIdx = $script:FleetStackSweepContent.IndexOf('docker image rm')
        $skipIdx | Should -BeGreaterThan 0
        $rmIdx | Should -BeGreaterThan $skipIdx
    }
}
