#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 6 Tests for SalmonRun.Deploy module
# Source: Scripts/1Deploy.ps1
# ==============================================================================

BeforeAll {
    $HelpersPath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1"
    $DeployPublicDir = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public"

    # Load helpers first (New-FleetCompose and other shared functions)
    . $HelpersPath

    # Load Public/*.ps1 functions from Core (replicates .psm1 behavior)
    $corePublic = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public"
    if (Test-Path $corePublic) { Get-ChildItem -Path $corePublic -Filter '*.ps1' | ForEach-Object { . $_.FullName } }

    # Load split modules for functions moved from Core (module-split E1-E4)
    $moduleDirs = @('SalmonRun.Secrets','SalmonRun.Identity','SalmonRun.Config','SalmonRun.Constants','SalmonRun.Process','SalmonRun.Fleet','SalmonRun.Images')
    foreach ($dir in $moduleDirs) {
        $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$dir.ps1"
        if (Test-Path $modulePath) { . $modulePath }
    }

    # Load deploy functions from module directory
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\SalmonRun.Deploy.ps1")

    # Stub helper functions (normally sourced from module files; override after loading)
    function script:Write-SetupLog { }
    function script:Get-HomeDir { Join-Path $env:USERPROFILE ".ORCHESTRATOR" }
    function script:Set-SwarmSecretSafe { }
    function script:Get-SecretFromAws { return $null }

    # Global docker mock — available in all runspaces including ForEach-Object -Parallel.
    # Individual tests override behavior via $script:DockerBehavior or by redefining
    # global:docker for specific test scenarios.
    $script:DockerCallLog = [System.Collections.Generic.List[string]]::new()
    $script:DockerBehavior = @{}
    function global:docker {
        $global:LASTEXITCODE = 0
        $null = $script:DockerCallLog.Add(($args -join ' '))
        $cmd = if ($args.Count -ge 2) { ($args[0..1]) -join ' ' } else { $args[0] }
        $allArgs = ($args -join ' ')
        $matchedKey = $script:DockerBehavior.Keys | Where-Object { $cmd -eq $_ -or $cmd -like $_ } | Select-Object -First 1
        if ($matchedKey) {
            $handler = $script:DockerBehavior[$matchedKey]
            return & $handler @args
        }
        switch -Wildcard ($cmd) {
            'volume ls'     { return @() }
            'volume create' { return "test-volume" }
            'volume rm'     { return $null }
            'info'          {
                if ($allArgs -match 'OSType') { return "linux" }
                if ($allArgs -match 'LocalNodeState') { return "active" }
                if ($allArgs -match 'Containers') { return "Swarm: active | Containers: 0 | Images: 18" }
                return "active"
            }
            'version'       {
                if ($allArgs -match 'json') { return $null }
                if ($allArgs -match 'Server\.Version') { return "24.0.0" }
                return $null
            }
            'run'           { return "test-container" }
            'cp'            { return "copied" }
            'exec'          { return "exec-ok" }
            'rm'            { return "removed" }
            'pull'          { return "pulled" }
            'network inspect' {
                if ($allArgs -match '--format') {
                    $netName = $args[2]
                    return "$netName overlay swarm"
                }
                return $null
            }
            'network create' { return "abcdef123456" }
            'network ls'     { return @() }
            'network rm'     { return "removed" }
            'secret ls' {
                if ($allArgs -match '--format') { return "test-secret" }
                if ($allArgs -match '--filter') { return "fake-secret-id" }
                return "fake-secret-id"
            }
            'secret create'  { return "fake-secret-id" }
            'secret rm'      { return "removed" }
            'stack services' { return @() }
            'stack ls'       { return @() }
            'stack rm'       { return $null }
            'service ls'     { return @() }
            'service inspect' { return "" }
            'service logs'   { return "log output" }
            'images'         { return "" }
            'image rm'       { return $null }
            'image inspect'  { return $null }
            'image build'    { return $null }
            'config create'  { return "config-id" }
            'config rm'      { return $null }
            'node ls'        { return "node1" }
            'ps*'             {
                if ($allArgs -match '--format.*Names') { return "abc123|oc-base" }
                if ($allArgs -match '--format.*\{\{\.ID\}\}$') { return "abc123" }
                if ($allArgs -match '--format.*ID') { return "abc123" }
                return "abc123|test-container|Up 2 hours"
            }
            default          { }
        }
    }
    $secretsMod = Get-Module SalmonRun.Secrets
    if ($secretsMod) {
        & $secretsMod { function Get-SecretFromAws { return $null } }
    }
    function global:Set-SwarmSecretSafe { }
    function global:Write-SetupLog { }
    function global:Get-SecretFromAws { return $null }

    # Helper to re-establish the base global:docker mock after a Describe block
    # that overrides it completes (used in Describe-level AfterEach blocks).
    function Restore-BaseDockerMock {
        Remove-Item -LiteralPath "function:global:docker" -Force -ErrorAction SilentlyContinue
        $script:DockerCallLog = [System.Collections.Generic.List[string]]::new()
        $script:DockerBehavior = @{}
        function global:docker {
            $global:LASTEXITCODE = 0
            $null = $script:DockerCallLog.Add(($args -join ' '))
            $cmd = if ($args.Count -ge 2) { ($args[0..1]) -join ' ' } else { $args[0] }
            $allArgs = ($args -join ' ')
            if ($script:DockerBehavior.ContainsKey($cmd)) {
                $handler = $script:DockerBehavior[$cmd]
                return & $handler @args
            }
            switch -Wildcard ($cmd) {
                'volume ls'     { return @() }
                'volume create' { return "test-volume" }
                'volume rm'     { return $null }
                'info'          {
                    if ($allArgs -match 'OSType') { return "linux" }
                    if ($allArgs -match 'LocalNodeState') { return "active" }
                    if ($allArgs -match 'Containers') { return "Swarm: active | Containers: 0 | Images: 18" }
                    return "active"
                }
                'version'       {
                    if ($allArgs -match 'json') { return $null }
                    if ($allArgs -match 'Server\.Version') { return "24.0.0" }
                    return $null
                }
                'run'           { return "test-container" }
                'cp'            { return "copied" }
                'exec'          { return "exec-ok" }
                'rm'            { return "removed" }
                'pull'          { return "pulled" }
                'network inspect' {
                    if ($allArgs -match '--format') {
                        $netName = $args[2]
                        return "$netName overlay swarm"
                    }
                    return $null
                }
                'network create' { return "abcdef123456" }
                'network ls'     { return @() }
                'network rm'     { return "removed" }
                'secret ls' {
                    if ($allArgs -match '--format') { return "test-secret" }
                    if ($allArgs -match '--filter') { return "fake-secret-id" }
                    return "fake-secret-id"
                }
                'secret create'  { return "fake-secret-id" }
                'secret rm'      { return "removed" }
                'stack services' { return @() }
                'stack ls'       { return @() }
                'stack rm'       { return $null }
                'service ls'     { return @() }
                'service inspect' { return "" }
                'service logs'   { return "log output" }
                'images'         { return "" }
                'image rm'       { return $null }
                'image inspect'  { return $null }
                'image build'    { return $null }
                'config create'  { return "config-id" }
                'config rm'      { return $null }
                'node ls'        { return "node1" }
                'ps*'             {
                    if ($allArgs -match '--format.*Names') { return "abc123|oc-base" }
                    if ($allArgs -match '--format.*\{\{\.ID\}\}$') { return "abc123" }
                    if ($allArgs -match '--format.*ID') { return "abc123" }
                    return "abc123|test-container|Up 2 hours"
                }
                default          { }
            }
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath "function:global:docker" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "function:global:Get-SecretFromAws" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "function:global:Set-SwarmSecretSafe" -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "function:global:Write-SetupLog" -Force -ErrorAction SilentlyContinue
}

Describe "Initialize-AgentVolumes" -Tag "Deploy" {
    BeforeEach {
        $script:StackName = "TEST"
        $script:AgentConfigs = @(
            [pscustomobject]@{
                Id          = 84
                AgentName   = "ORCH-84"
                Role        = "ORCH"
                Index       = 0
                Prefix      = "TEST_ORCH_84"
                GatewayPort = 20100
            }
        )
        $script:RoleFileMap = @{ "ORCH" = @("role.md") }
        $script:SharedFiles  = @()
        $script:TargetDir    = $TestDrive
        $script:SovereigntyTier = "global"

        # Seed dummy files expected by the function
        $RoleDir = Join-Path $TestDrive "Agents" "ORCH"
        New-Item -ItemType Directory -Path $RoleDir -Force | Out-Null
        "role" | Set-Content -Path (Join-Path $RoleDir "role.md")

        $SovDir = Join-Path $RoleDir "Global"
        New-Item -ItemType Directory -Path $SovDir -Force | Out-Null
        '{"agents":{},"models":{"providers":{"test":{"models":[{"id":"test-model"}]}}}}' | Set-Content -Path (Join-Path $SovDir "ORCHESTRATOR.json")

        $InfraDir = Join-Path $TestDrive "Infrastructure"
        New-Item -ItemType Directory -Path $InfraDir -Force | Out-Null
        "#!/bin/sh" | Set-Content -Path (Join-Path $InfraDir "entrypoint.sh")
    }

    # Shadow docker with a local function so tests run in-process (no Start-Job).

    Context "When agent volumes do not exist" {
        It "Completes without errors" {
            function Copy-FilesToVolume { return $true }
            function Test-InterclawConfigSchema { return @{ Valid = $true; Errors = @(); Warnings = @() } }
            { Initialize-AgentVolumes -StackName $script:StackName -TargetDir $script:TargetDir -SovereigntyTier $script:SovereigntyTier -AgentConfigs ($script:AgentConfigs | ForEach-Object { @{ Id = $_.Id; AgentName = $_.AgentName; Role = $_.Role; Index = $_.Index; Prefix = $_.Prefix; GatewayPort = $_.GatewayPort } }) } | Should -Not -Throw
        }
    }

    Context "When agent volumes already exist" {
        It "Skips volume creation" {
            $global:TestCallLog = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            function global:docker {
                $global:LASTEXITCODE = 0
                $global:TestCallLog.Add(($args -join ' '))
                if ($args[0] -eq 'volume' -and $args[1] -eq 'ls') { return "existing" }
                if ($args[0] -eq 'run') { return "dummy-container" }
            }
            function Copy-FilesToVolume { return $true }
            function Test-InterclawConfigSchema { return @{ Valid = $true; Errors = @(); Warnings = @() } }
            Initialize-AgentVolumes -StackName $script:StackName -TargetDir $script:TargetDir -SovereigntyTier $script:SovereigntyTier -AgentConfigs ($script:AgentConfigs | ForEach-Object { @{ Id = $_.Id; AgentName = $_.AgentName; Role = $_.Role; Index = $_.Index; Prefix = $_.Prefix; GatewayPort = $_.GatewayPort } })
            $createCalls = $global:TestCallLog.ToArray() | Where-Object { $_ -match '^volume create' }
            $createCalls.Count | Should -Be 0
            Remove-Item -LiteralPath "function:global:docker" -Force -ErrorAction SilentlyContinue
            Remove-Variable -Name TestCallLog -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe "Copy-FilesToVolume" -Tag "Deploy" {
    BeforeEach {
        $script:TestVolName = "test-vol-cftv-$(Get-Random)"
        $global:TestCallLog = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
        function global:docker {
            $global:LASTEXITCODE = 0
            $global:TestCallLog.Add(($args -join ' '))
            if ($args[0] -eq 'run' -and $args[1] -eq '-d') { return "test-container-id" }
            if ($args[0] -eq 'cp') { return "copied" }
            if ($args[0] -eq 'exec') { return "exec-ok" }
            if ($args[0] -eq 'rm') { return "removed" }
        }
        function Write-SetupLog { }
        function Invoke-NativeCommand {
            param([scriptblock]$ScriptBlock)
            $output = & $ScriptBlock
            return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = "$output" }
        }
    }

    AfterEach {
        Restore-BaseDockerMock
        Remove-Variable -Name TestCallLog -Scope Global -ErrorAction SilentlyContinue
    }

    Context "Batch copy with multiple files" {
        It "Creates one container and copies all files" {
            $Files = @(
                @{ Source = "C:\test\file1.txt"; Target = "file1.txt" }
                @{ Source = "C:\test\file2.md"; Target = "subdir/file2.md" }
                @{ Source = "C:\test\file3.json"; Target = "file3.json" }
            )
            Copy-FilesToVolume -VolumeName $script:TestVolName -Files $Files -Description "test batch"

            $callArray = $global:TestCallLog.ToArray()
            ($callArray -match "^run -d").Count | Should -BeGreaterOrEqual 1
            ($callArray -match "^cp").Count | Should -Be 3
            ($callArray -match "^rm -f").Count | Should -Be 1
        }
    }

    Context "Batch copy with exec commands" {
        It "Runs post-copy exec commands" {
            $Files = @(@{ Source = "C:\test\entrypoint.sh"; Target = "entrypoint.sh" })
            Copy-FilesToVolume -VolumeName $script:TestVolName -Files $Files `
                -ExecCommands @("chmod +x /target/entrypoint.sh", "chown -R 1000:1000 /target") `
                -Description "test batch with exec"

            $callArray = $global:TestCallLog.ToArray()
            ($callArray -match "^exec").Count | Should -Be 2
        }
    }

    Context "Uses alpine:latest image" {
        It "Creates container with alpine:latest" {
            $Files = @(@{ Source = "C:\test\file.txt"; Target = "file.txt" })
            Copy-FilesToVolume -VolumeName $script:TestVolName -Files $Files -Description "test image"

            $callArray = $global:TestCallLog.ToArray()
            $runCall = $callArray | Where-Object { $_ -match "^run -d" } | Select-Object -First 1
            $runCall | Should -Match "alpine:latest"
        }
    }

    Context "Cleans up container in finally block" {
        It "Removes container even when docker cp fails" {
            $global:TestCallLog = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
            function global:docker {
                $global:TestCallLog.Add(($args -join ' '))
                if ($args[0] -eq 'run' -and $args[1] -eq '-d') { return "test-container-id" }
                if ($args[0] -eq 'cp') { throw "docker cp failed" }
                if ($args[0] -eq 'rm') { return "removed" }
            }
            function Invoke-NativeCommand {
                param([scriptblock]$ScriptBlock)
                $output = & $ScriptBlock
                return [pscustomobject]@{ Success = $true; ExitCode = 0; Output = "$output" }
            }

            $Files = @(@{ Source = "C:\test\fail.txt"; Target = "fail.txt" })
            Copy-FilesToVolume -VolumeName $script:TestVolName -Files $Files -Description "test cleanup"

            $callArray = $global:TestCallLog.ToArray()
            ($callArray -match "^rm -f").Count | Should -Be 1
        }
    }
}

Describe "Initialize-SwarmReadiness" -Tag "Deploy" {
    BeforeEach {
        $global:LASTEXITCODE = 0
        $script:DockerCallLog.Clear()
    }

    Context "When Swarm is already active" {
        It "Does not call docker swarm init" {
            $script:DockerBehavior['info --format'] = { return "active" }
            Initialize-SwarmReadiness
            (@($script:DockerCallLog.ToArray()) -match 'swarm init').Count | Should -Be 0
        }
    }

    Context "When Swarm is not active and init succeeds" {
        It "Initializes the Swarm" {
            $script:DockerBehavior['info --format'] = { return "inactive" }
            Initialize-SwarmReadiness
            (@($script:DockerCallLog.ToArray()) -match 'swarm init').Count | Should -Be 1
        }
    }

    Context "When Swarm is not active and init fails" {
        It "Throws a clear error" {
            $script:DockerBehavior['info --format'] = { return "inactive" }
            $script:DockerBehavior['swarm init'] = {
                $global:LASTEXITCODE = 1
                return "Error"
            }
            { Initialize-SwarmReadiness } | Should -Throw "*Docker Swarm initialization failed*"
            (@($script:DockerCallLog.ToArray()) -match 'swarm init').Count | Should -Be 1
        }
    }
}

Describe "Publish-FleetStack" -Tag "Deploy" {
    BeforeEach {
        $script:StackName = "TEST"
        $localTestDrive = $TestDrive
        $deployMod = Get-Module SalmonRun.Deploy
        if ($deployMod) { & $deployMod { $script:StackName = "TEST"; $script:TargetDir = $localTestDrive } }
        $script:AgentConfigs = @(
            [pscustomobject]@{
                Id          = 84
                AgentName   = "ORCH-84"
                Role        = "ORCH"
                Index       = 0
                Prefix      = "TEST_ORCH_84"
                GatewayPort = 20100
            }
        )
        $script:TargetDir       = $TestDrive
        $script:ProjectCode     = "TEST"
        $script:InstallGithubToken = "false"
        $script:SovereigntyTier = "canada"
        $script:InstallTailscale = "false"
        $script:ImageVersion    = "local"
        $global:LASTEXITCODE    = 0

        New-Item -ItemType Directory -Path (Join-Path $TestDrive "Infrastructure") -Force | Out-Null
        $ComposePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
        "version: '3'" | Set-Content -Path $ComposePath

        $script:DockerCallLog = [System.Collections.Generic.List[string]]@()
        $script:DockerBehavior = @{}
        # Override global:docker for this Describe — resets any overrides from
        # earlier tests. The AfterEach no longer cleans it up (BeforeAll provides
        # the base mock), but BeforeEach redefines it for clean isolation.
        function global:docker {
            $global:LASTEXITCODE = 0
            $null = $script:DockerCallLog.Add(($args -join ' '))
            $cmd = ($args[0..1]) -join ' '
            $allArgs = ($args -join ' ')
            if ($script:DockerBehavior.ContainsKey($cmd)) {
                $handler = $script:DockerBehavior[$cmd]
                return & $handler @args
            }
            switch -Wildcard ($cmd) {
                'info*'    {
                    if ($allArgs -match 'OSType') { return "linux" }
                    if ($allArgs -match 'LocalNodeState') { return "active" }
                    if ($allArgs -match 'Containers') { return "Swarm: active | Containers: 0 | Images: 18" }
                    return "active"
                }
                'version*' {
                    if ($allArgs -match 'Server\.Version') { return "24.0.0" }
                    return $null
                }
                'network inspect' {
                    if ($allArgs -match '--format') {
                        $netName = $args[2]
                        return "$netName overlay swarm"
                    }
                    return $null
                }
                'network rm'   { return "removed" }
                'network create' { return "abcdef123456" }
                'network ls' { return $null }
                'secret ls'{
                    if ($allArgs -match '--format') { return "test-secret" }
                    if ($allArgs -match '--filter') { return "fake-secret-id" }
                    return "fake-secret-id"
                }
                'secret create' { return "fake-secret-id" }
                'secret rm'   { return "removed" }
                default            { }
            }
        }
        # Stub AWS/secret functions inside the Secrets module scope so module
        # functions (at script scope) are shadowed by module-scoped overrides.
        $secretsMod = Get-Module SalmonRun.Secrets
        if ($secretsMod) {
            & $secretsMod { function Get-SecretFromAws { return $null } }
        }
        function global:Set-SwarmSecretSafe { }
        function global:Write-SetupLog { }
    }

    AfterEach {
        Restore-BaseDockerMock
        Remove-Item -LiteralPath "function:global:Get-SecretFromAws" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "function:global:Set-SwarmSecretSafe" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "function:global:Write-SetupLog" -Force -ErrorAction SilentlyContinue
    }

    Context "With -SkipDeploy switch" {
        It "Generates compose but does not deploy the stack" -Tag "RequiresDeployment" {
            $script:DockerCallLog.Clear()
            $composePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
            $global:TestComposePath = $composePath
            $agentHashtables = $script:AgentConfigs | ForEach-Object { @{ Id = $_.Id; AgentName = $_.AgentName; Role = $_.Role; Index = $_.Index; Prefix = $_.Prefix; GatewayPort = $_.GatewayPort } }
            $deployMod = Get-Module SalmonRun.Deploy
            if ($deployMod) { & $deployMod { function New-FleetCompose { param($Agents) return $global:TestComposePath } } }
            Publish-FleetStack -SkipDeploy -StackName $script:StackName -AgentConfigs $agentHashtables -ProjectCode "TEST"
            ($script:DockerCallLog -match '^stack deploy').Count | Should -Be 0
        }
    }

    Context "When no previous stack exists" {
        It "Deploys the stack successfully" -Tag "RequiresDeployment" {
            $script:DockerCallLog.Clear()
            function global:New-FleetCompose { return (Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml") }
            Publish-FleetStack
            ($script:DockerCallLog -match 'secret ls --format').Count | Should -Be 1
        }
    }

    Context "Pre-flight volume verification" {
        It "Auto-creates missing volumes instead of aborting" -Tag "RequiresDeployment" {
            $ComposeContent = @"
version: "3.8"
services:
  test:
    image: testimage
secrets:
  test_secret:
    external: true
volumes:
  test_vol:
    external: true
"@
            $ComposePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
            Set-Content -Path $ComposePath -Value $ComposeContent

            $script:DockerCallLog.Clear()
            $script:DockerBehavior['secret ls'] = {
                $allArgs2 = $args -join ' '
                if ($allArgs2 -match '--format') { return "test_secret" }
                if ($allArgs2 -match '--filter') { return "fake-secret-id" }
                return "fake-secret-id"
            }
            function New-FleetCompose { return $ComposePath }

            Publish-FleetStack
            ($script:DockerCallLog -match '^volume create').Count | Should -BeGreaterThan 0
            ($script:DockerCallLog -match 'stack deploy').Count | Should -Be 1
        }

        It "Proceeds when all expected volumes exist" -Tag "RequiresDeployment" {
            $ComposeContent = @"
version: "3.8"
services:
  test:
    image: testimage
secrets:
  test_secret:
    external: true
volumes:
  test_vol:
    external: true
"@
            $ComposePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
            Set-Content -Path $ComposePath -Value $ComposeContent

            $script:DockerCallLog.Clear()
            $script:DockerBehavior['secret ls'] = {
                $allArgs2 = $args -join ' '
                if ($allArgs2 -match '--format') { return "test_secret" }
                if ($allArgs2 -match '--filter') { return "fake-secret-id" }
                return "fake-secret-id"
            }
            function New-FleetCompose { return $ComposePath }
            Publish-FleetStack
            ($script:DockerCallLog -match 'stack deploy').Count | Should -Be 1
        }

        It "Calls Remove-OrphanedVolumes twice (before and after deploy)" -Tag "RequiresDeployment" {
            $ComposeContent = @"
version: "3.8"
services:
  test:
    image: testimage
secrets:
  test_secret:
    external: true
volumes:
  test_vol:
    external: true
"@
            $ComposePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
            Set-Content -Path $ComposePath -Value $ComposeContent

            $script:DockerCallLog.Clear()
            $script:RemoveOrphanedCalls = 0
            $script:DockerBehavior['secret ls'] = {
                $allArgs2 = $args -join ' '
                if ($allArgs2 -match '--format') { return "test_secret" }
                if ($allArgs2 -match '--filter') { return "fake-secret-id" }
                return "fake-secret-id"
            }
            function New-FleetCompose { return $ComposePath }
            function Remove-OrphanedVolumes { $script:RemoveOrphanedCalls++ }
            Publish-FleetStack
            $script:RemoveOrphanedCalls | Should -Be 2
        }

        It "Purges stale Swarm healthcheck from is-fleet after deploy" -Tag "RequiresDeployment" {
            $ComposeContent = @"
version: "3.8"
services:
  test:
    image: testimage
"@
            $ComposePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
            Set-Content -Path $ComposePath -Value $ComposeContent
            $script:DockerCallLog.Clear()
            function New-FleetCompose { return $ComposePath }
            function Remove-OrphanedVolumes { }
            Publish-FleetStack
            ($script:DockerCallLog -match '^service update --health-cmd="" TEST_is-fleet').Count | Should -Be 1
        }
    }
}

Describe "Publish-FleetStack network creation" -Tag "Deploy" {
    BeforeEach {
        $script:StackName = "TEST"
        $deployMod = Get-Module SalmonRun.Deploy
        if ($deployMod) { & $deployMod { $script:StackName = "TEST"; $script:TargetDir = $using:TestDrive } }
        $script:AgentConfigs = @(
            [pscustomobject]@{
                Id          = 84
                AgentName   = "ORCH-84"
                Role        = "ORCH"
                Index       = 0
                Prefix      = "TEST_ORCH_84"
                GatewayPort = 20100
            }
        )
        $script:TargetDir       = $TestDrive
        $script:ProjectCode     = "TEST"
        $script:InstallGithubToken = "false"
        $script:SovereigntyTier = "canada"
        $script:InstallTailscale = "false"
        $script:ImageVersion    = "local"
        $global:LASTEXITCODE    = 0

        New-Item -ItemType Directory -Path (Join-Path $TestDrive "Infrastructure") -Force | Out-Null
        $ComposePath = Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml"
        "version: '3'" | Set-Content -Path $ComposePath

        $script:DockerCallLog = [System.Collections.Generic.List[string]]@()
        $script:DockerBehavior = @{}
        function global:docker {
            $global:LASTEXITCODE = 0
            $null = $script:DockerCallLog.Add(($args -join ' '))
            $cmd = ($args[0..1]) -join ' '
            $allArgs = ($args -join ' ')
            if ($script:DockerBehavior.ContainsKey($cmd)) {
                $handler = $script:DockerBehavior[$cmd]
                return & $handler @args
            }
            switch -Wildcard ($cmd) {
                'info*'    {
                    if ($allArgs -match 'OSType') { return "linux" }
                    if ($allArgs -match 'LocalNodeState') { return "active" }
                    if ($allArgs -match 'Containers') { return "Swarm: active | Containers: 0 | Images: 18" }
                    return "active"
                }
                'version*' {
                    if ($allArgs -match 'Server\.Version') { return "24.0.0" }
                    return $null
                }
                'network inspect' {
                    if ($allArgs -match '--format') {
                        $netName = $args[2]
                        return "$netName overlay swarm"
                    }
                    return $null
                }
                'network rm'   { return "removed" }
                'network create' { return "abcdef123456" }
                'network ls' { return $null }
                'secret ls'{
                    if ($allArgs -match '--format') { return "test-secret" }
                    if ($allArgs -match '--filter') { return "fake-secret-id" }
                    return "fake-secret-id"
                }
                'secret create' { return "fake-secret-id" }
                'secret rm'   { return "removed" }
                default            { }
            }
        }
        $secretsMod = Get-Module SalmonRun.Secrets
        if ($secretsMod) {
            & $secretsMod { function Get-SecretFromAws { return $null } }
        }
        function global:Set-SwarmSecretSafe { }
        function global:Write-SetupLog { }
    }

    AfterEach {
        Restore-BaseDockerMock
        Remove-Item -LiteralPath "function:global:Get-SecretFromAws" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "function:global:Set-SwarmSecretSafe" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "function:global:Write-SetupLog" -Force -ErrorAction SilentlyContinue
    }

    Context "When network creation fails after all retries" {
        It "Includes swarm diagnostic info in the error" -Tag "RequiresDeployment" {
            $script:DockerBehavior['network create'] = {
                $global:LASTEXITCODE = 1
                return "Error response from daemon: pool overlaps with other one"
            }
            function New-FleetCompose { return (Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml") }
            { Publish-FleetStack } | Should -Throw "*Failed to create Docker overlay network*"
        }
    }

    Context "When swarm is not active before network creation" {
        It "Re-initializes swarm and fails with clear error if re-init fails" -Tag "RequiresDeployment" {
            $script:DockerBehavior['info --format'] = { return "inactive" }
            $script:DockerBehavior['swarm init'] = {
                $global:LASTEXITCODE = 1
                return "Error response from daemon: This node is already part of a swarm"
            }
            function New-FleetCompose { return (Join-Path $TestDrive "Infrastructure/docker-compose.interclaw.yml") }
            { Publish-FleetStack } | Should -Throw "*Swarm is not active*"
        }
    }
}

Describe "Remove-OrphanedVolumes" -Tag "Deploy" {
    BeforeEach {
        $script:DockerCallLog.Clear()
        $script:StackName = "TEST"
        $script:AgentConfigs = @(
            [pscustomobject]@{
                Id          = 84
                AgentName   = "ORCH-84"
                Role        = "ORCH"
                Index       = 0
                Prefix      = "TEST_ORCH_84"
                GatewayPort = 20100
            }
        )
        function Write-Host { }
        function Write-SetupLog { }
        function Get-AgentServiceName { return "oc-orch" }
    }

    Context "CleanDoublePrefixed" {
        It "removes FRAD_FRAD_* volumes and logs distinctly" {
            $script:DockerBehavior['volume ls'] = {
                return @(
                    "TEST_agent_config_oc-orch"
                    "TEST_agent_persist_oc-orch"
                    "TEST_TEST_agent_config_oc-orch"
                )
            }
            $script:DockerBehavior['volume rm'] = { $global:LASTEXITCODE = 0; return $null }
            Remove-OrphanedVolumes -StackName "TEST" -AgentConfigs $script:AgentConfigs -CleanDoublePrefixed
            $rmCalls = $script:DockerCallLog.ToArray() | Where-Object { $_ -match 'volume rm TEST_TEST_' }
            $rmCalls.Count | Should -Be 1
        }
    }

    Context "UseLabels" {
        It "queries by label when -UseLabels is set" {
            $script:DockerBehavior['volume ls'] = {
                $filterArg = $args | Where-Object { $_ -match 'label=' }
                if ($filterArg) {
                    return @("TEST_agent_config_oc-orch")
                }
                return @()
            }
            Remove-OrphanedVolumes -StackName "TEST" -AgentConfigs $script:AgentConfigs -UseLabels
            $labelCalls = $script:DockerCallLog.ToArray() | Where-Object { $_ -match 'label=com.interclaw.stack' }
            $labelCalls.Count | Should -BeGreaterThan 0
        }

        It "falls back to name prefix when -UseLabels is not set" {
            $script:DockerBehavior['volume ls'] = {
                $filterArg = $args | Where-Object { $_ -match 'label=' }
                if ($filterArg) {
                    return @()
                }
                return @("TEST_agent_config_oc-orch", "TEST_agent_persist_oc-orch")
            }
            Remove-OrphanedVolumes -StackName "TEST" -AgentConfigs $script:AgentConfigs
            $labelCalls = $script:DockerCallLog.ToArray() | Where-Object { $_ -match 'label=com.interclaw.stack' }
            $labelCalls.Count | Should -Be 0
        }
    }
}

Describe "Test-FleetDeployment" -Tag "Deploy" {
    BeforeEach {
        $script:StackName = "TEST"
        $script:AgentConfigs = @(
            [pscustomobject]@{
                Id          = 84
                AgentName   = "ORCH-84"
                Role        = "ORCH"
                Index       = 0
                Prefix      = "TEST_ORCH_84"
                GatewayPort = 20100
            }
        )
        $script:ProjectCode  = "TEST"
        $script:ImageVersion = "local"
    }

    Context "When all services are healthy" {
        It "Reports success with no failures" {
            $script:DockerBehavior['stack services'] = {
                return @(
                    "oc-orch`t1/1`tORCHESTRATOR:local"
                    "sentry`t1/1`tsentry:local"
                )
            }
            function global:Start-Sleep { }
            $constantsMod = Get-Module SalmonRun.Constants
            if ($constantsMod) { & $constantsMod { $script:InterclawConstants = @{ HealthCheckMaxRetries = 1; HealthCheckRetryIntervalSec = 0; HealthCheckMaxParallelChecks = 5; PostCleanupWaitSec = 0 } } }
            $global:InterclawConstants = @{ HealthCheckMaxRetries = 1; HealthCheckRetryIntervalSec = 0; HealthCheckMaxParallelChecks = 5; PostCleanupWaitSec = 0 }
            $global:LASTEXITCODE = 0
            $agentHashtables = $script:AgentConfigs | ForEach-Object { @{ Id = $_.Id; AgentName = $_.AgentName; Role = $_.Role; Index = $_.Index; Prefix = $_.Prefix; GatewayPort = $_.GatewayPort } }
            Test-FleetDeployment -StackName $script:StackName -AgentConfigs $agentHashtables -ProjectCode $script:ProjectCode -SovereigntyTier "global" -ImageVersion $script:ImageVersion
            ($script:DockerCallLog.ToArray() -match '^stack services').Count | Should -Be 1
        }
    }

    Context "When a service has zero replicas" {
        It "Detects the failing service and fetches logs" {
            $script:DockerBehavior['stack services'] = {
                return @(
                    "oc-orch`t0/1`tORCHESTRATOR:local"
                    "sentry`t1/1`tsentry:local"
                )
            }
            $script:DockerBehavior['service logs'] = { return "log output" }
            function global:Start-Sleep { }
            $constantsMod = Get-Module SalmonRun.Constants
            if ($constantsMod) { & $constantsMod { $script:InterclawConstants = @{ HealthCheckMaxRetries = 1; HealthCheckRetryIntervalSec = 0; HealthCheckMaxParallelChecks = 5; PostCleanupWaitSec = 0 } } }
            $global:InterclawConstants = @{ HealthCheckMaxRetries = 1; HealthCheckRetryIntervalSec = 0; HealthCheckMaxParallelChecks = 5; PostCleanupWaitSec = 0 }
            $global:LASTEXITCODE = 0
            $agentHashtables = $script:AgentConfigs | ForEach-Object { @{ Id = $_.Id; AgentName = $_.AgentName; Role = $_.Role; Index = $_.Index; Prefix = $_.Prefix; GatewayPort = $_.GatewayPort } }
            Test-FleetDeployment -StackName $script:StackName -AgentConfigs $agentHashtables -ProjectCode $script:ProjectCode -SovereigntyTier "global" -ImageVersion $script:ImageVersion
            ($script:DockerCallLog.ToArray() -match '^service logs').Count | Should -Be 1
        }
    }
}

Describe "Invoke-FleetImageBuild" -Tag "Deploy", "RequiresDeployment" {
    BeforeEach {
        $script:TargetDir = $TestDrive
        $script:ImageVersion = "test"

        # Seed Dockerfile
        $InfraDir = Join-Path $TestDrive "Infrastructure"
        New-Item -ItemType Directory -Path $InfraDir -Force | Out-Null
        "FROM scratch" | Set-Content -Path (Join-Path $InfraDir "fleet.Dockerfile")

        # Mock docker in Images module scope to force build failure
        $imagesMod = Get-Module SalmonRun.Images
        if ($imagesMod) { & $imagesMod { function docker { $global:LASTEXITCODE = 1 } } }
    }

    It "throws when docker build exits with non-zero code" -Skip {
        $script:DockerBehavior['image inspect'] = { return $null }
        function Write-SetupLog { }

        { Invoke-FleetImageBuild -TargetDir $script:TargetDir } | Should -Throw "Docker build exited with code 1"
    }
}

Describe "Invoke-OpencodeImageBuild" -Tag "Deploy", "RequiresDeployment" {
    BeforeEach {
        $script:TargetDir = $TestDrive

        $OpencodeDir = Join-Path $TestDrive "Infrastructure" "opencode"
        New-Item -ItemType Directory -Path $OpencodeDir -Force | Out-Null
        "FROM scratch" | Set-Content -Path (Join-Path $OpencodeDir "Dockerfile")
    }

    It "throws when docker build exits with non-zero code" -Skip {
        function Write-SetupLog { }

        { Invoke-OpencodeImageBuild -TargetDir $script:TargetDir } | Should -Throw "Docker build exited with code 1"
    }
}

Describe "Invoke-ProxyImageBuild" -Tag "Deploy", "RequiresDeployment" {
    BeforeEach {
        $script:TargetDir = $TestDrive

        $InfraDir = Join-Path $TestDrive "Infrastructure"
        New-Item -ItemType Directory -Path $InfraDir -Force | Out-Null
        "FROM scratch" | Set-Content -Path (Join-Path $InfraDir "api-proxy.Dockerfile")
    }

    It "throws when docker build exits with non-zero code" -Skip {
        function Write-SetupLog { }

        { Invoke-ProxyImageBuild -TargetDir $script:TargetDir } | Should -Throw "Docker build exited with code 1"
    }
}

Describe "New-FleetAliases" -Tag "Deploy" {
    BeforeEach {
        $savedHome = $env:HOME
        $savedUserProfile = $env:USERPROFILE
        $env:HOME = $TestDrive
        $env:USERPROFILE = $TestDrive
        $pathsMod = Get-Module SalmonRun.Paths
        if ($pathsMod) { & $pathsMod { $script:CachedHomeDir = $null } }
    }

    AfterEach {
        $env:HOME = $savedHome
        $env:USERPROFILE = $savedUserProfile
    }

    Context "With running containers" {
        It "Writes alias file containing agent exec functions" {
            function Write-Host { }
            function Start-Sleep { }
            $deployMod = Get-Module SalmonRun.Deploy
            if ($deployMod) { & $deployMod { $script:ProjectCode = "TEST"; $script:SovereigntyTier = "global"; $script:AgentConfigs = @(@{ Id = 84; AgentName = "ORCH-84"; Role = "ORCH"; Index = 0; Prefix = "TEST_ORCH_84"; GatewayPort = 20100 }) } }
            $script:DockerBehavior['ps'] = { return "abc123|oc-base" }
            $script:DockerBehavior['service ls'] = { return "sentry_test" }
            $script:StackName = "TEST"
            New-FleetAliases -StackName "TEST"
            $Content = Get-Content (Join-Path $TestDrive ".ORCHESTRATOR" ".fleet-aliases.ps1") -Raw
            $Content | Should -Match "function global:base"
            $Content | Should -Not -Match "function global:base-84"
        }
    }

    Context "With no matching containers" {
        It "Still writes the alias file with fleet metadata" {
            function Write-Host { }
            function Start-Sleep { }
            $deployMod = Get-Module SalmonRun.Deploy
            if ($deployMod) { & $deployMod { $script:ProjectCode = "TEST"; $script:SovereigntyTier = "global"; $script:AgentConfigs = @(@{ Id = 84; AgentName = "ORCH-84"; Role = "ORCH"; Index = 0; Prefix = "TEST_ORCH_84"; GatewayPort = 20100 }) } }
            $script:DockerBehavior['ps'] = { return "" }
            $script:DockerBehavior['service ls'] = { return "" }
            $script:StackName = "TEST"
            New-FleetAliases -StackName "TEST"
            $Content = Get-Content (Join-Path $TestDrive ".ORCHESTRATOR" ".fleet-aliases.ps1") -Raw
            $Content | Should -Match "ORCHESTRATOR_FLEET_PROJECT = 'TEST'"
        }
    }
}

Describe "1Deploy.ps1 parameter block uniqueness" -Tag "Deploy", "Regression-Only" {
    It "has exactly one param() block" {
        $deployPath = Join-Path $PSScriptRoot "..\1Deploy.ps1"
        $content = Get-Content -LiteralPath $deployPath -Raw
        $paramMatches = [regex]::Matches($content, '(?m)^param\(', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $paramMatches.Count | Should -Be 1
    }
}

Describe "ConvertTo-ComposeYamlScalar" -Tag "Deploy" {
    It "escapes backslashes for Windows paths" {
        $result = ConvertTo-ComposeYamlScalar -Value "C:\Users\test"
        $result | Should -Be '"C:\\Users\\test"'
    }

    It "escapes double quotes inside strings" {
        $result = ConvertTo-ComposeYamlScalar -Value 'Say "hello" world'
        $result | Should -Be '"Say \"hello\" world"'
    }

    It "handles backslash before quote correctly" {
        $result = ConvertTo-ComposeYamlScalar -Value 'C:\Files\"data"'
        $result | Should -Be '"C:\\Files\\\"data\""'
    }

    It "returns plain strings without special chars unquoted" {
        $result = ConvertTo-ComposeYamlScalar -Value "hello-world"
        $result | Should -Be "hello-world"
    }

    It "returns null as literal null" {
        $result = ConvertTo-ComposeYamlScalar -Value $null
        $result | Should -Be "null"
    }

    It "returns booleans as lowercase" {
        $result = ConvertTo-ComposeYamlScalar -Value $true
        $result | Should -Be "true"
    }

    It "returns integers as-is" {
        $result = ConvertTo-ComposeYamlScalar -Value 42
        $result | Should -Be "42"
    }

    It "returns empty string as double quotes" {
        $result = ConvertTo-ComposeYamlScalar -Value ""
        $result | Should -Be '""'
    }
}
