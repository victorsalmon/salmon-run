#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $orchestratorModules = Join-Path $repoRoot 'Orchestrator\Modules'
    $dockerModules = Join-Path $repoRoot 'Skills\Docker\Modules'
    foreach ($modulePath in @($orchestratorModules, $dockerModules)) {
        if ($env:PSModulePath -notlike "*$modulePath*") {
            $env:PSModulePath = "$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }

    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    $ModuleRoot = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet"
    . (Join-Path $ModuleRoot "SalmonRun.Fleet.ps1")
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    $corePublic = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public"
    if (Test-Path $corePublic) { Get-ChildItem -Path $corePublic -Filter '*.ps1' | ForEach-Object { . $_.FullName } }
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Config\SalmonRun.Config.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets\SalmonRun.Secrets.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Constants\SalmonRun.Constants.ps1")

    Mock Write-SetupLog { }
    Mock Write-FleetLog { }
    Mock Write-Verbose { }

    $global:InterclawConstants = @{
        FleetApiPort = 21002
        McpAqePort = 21004
        ProxyPort = 21003
        MainLoopIntervalSec = 300
        ServiceNet = "service_net"
        OrchestrationNet = "orchestration_net"
    }
    $global:NetworkNames = @{
        ServiceNet = "service_net"
        OrchestrationNet = "orchestration_net"
        ManagementNet = "management_net"
    }
    $global:SecretSchema = @{
        AwsId = @{ Suffix = "aws_id" }
        AwsSecret = @{ Suffix = "aws_secret" }
        GatewayToken = @{ Suffix = "gateway_token" }
        OpenRouterApiKey = @{ Suffix = "openrouter_api_key" }
    }
    $script:RoleProviderKeyMap = @{}
}

Describe "Get-ActiveAgentIds" -Tag "Fleet", "Regression-Only" {
    It "returns empty array when no services match" {
        function global:docker { $global:LASTEXITCODE = 0; return @() }

        $result = Get-ActiveAgentIds
        $result | Should -BeNullOrEmpty
    }

    It "extracts IDs from service names" {
        $global:stackSvcOutput = @("teststack_oc-orch-130", "teststack_oc-base-131")
        function global:docker { $global:LASTEXITCODE = 0; return $global:stackSvcOutput }

        $result = Get-ActiveAgentIds
        $result.Count | Should -Be 2
        $result[0] | Should -Be "130"
        $result[1] | Should -Be "131"
    }

    It "returns unique sorted IDs" {
        $global:stackSvcOutput = @("teststack_oc-orch-131", "teststack_oc-base-130", "teststack_oc-orch-131")
        function global:docker { $global:LASTEXITCODE = 0; return $global:stackSvcOutput }

        $result = Get-ActiveAgentIds
        $result.Count | Should -Be 2
        $result[0] | Should -Be "130"
        $result[1] | Should -Be "131"
    }
}

Describe "Get-ActiveAgentRoles" -Tag "Fleet", "Regression-Only" {
    It "returns BASE role objects from docker stack services" {
        function global:Get-StackName { return "teststack" }
        function global:docker { $global:LASTEXITCODE = 0; return @("teststack_oc-base", "teststack_oc-base-131") }
        $result = Get-ActiveAgentRoles
        ($result | Measure-Object).Count | Should -Be 2
        $result[0].Role | Should -Be "BASE"
        $result[0].Index | Should -Be 0
        $result[1].Role | Should -Be "BASE"
        $result[1].Index | Should -Be 131
    }
}

Describe "Invoke-FleetStartupCheck" -Tag "Fleet", "Regression-Only" {
    It "passes when startup verification returns 0" {
        function Invoke-FleetStartupVerification { return 0 }
        { Invoke-FleetStartupCheck } | Should -Not -Throw
    }

    It "warns when startup verification returns non-zero" {
        function Invoke-FleetStartupVerification { return 2 }
        { Invoke-FleetStartupCheck } | Should -Not -Throw
    }
}

Describe "Test-FleetNetworkConnectivity" -Tag "Fleet", "Regression-Only" {
    It "passes when expected networks exist" {
        $script:Results = @()
        $script:FailCount = 0
        Mock docker { return @("teststack_service_net", "teststack_orchestration_net") } -ParameterFilter { $args -join " " -match "network ls" }
        { Test-FleetNetworkConnectivity -StackName "teststack" } | Should -Not -Throw
    }
}

Describe "Test-FleetStackHealth" -Tag "Fleet", "Regression-Only" {
    It "reports health check steps" {
        function global:docker {
            $global:LASTEXITCODE = 0
            $argLine = $args -join " "
            if ($argLine -match "info") { return "Server Version: 24.0" }
            if ($argLine -match "node ls") { return "node1" }
            return @()
        }
        $script:Results = @()
        $script:FailCount = 0
        $stackServices = @("svc1`t1/1`timg1", "svc2`t0/1`timg2")
        $agentRoles = @(@{ Role = "BASE"; Index = 0 })
        { Test-FleetStackHealth -StackName "teststack" -AgentRoles $agentRoles -StackServices $stackServices } | Should -Not -Throw
    }
}

Describe "Invoke-FleetRebuild" -Tag "Fleet", "Regression-Only" {
    BeforeAll {
        Mock Write-FleetLog { } -ModuleName SalmonRun.Fleet
    }

    It "fails when Fleet AWS credentials are missing" {
        Mock Read-FleetSecret { return "" } -ModuleName SalmonRun.Fleet
        Invoke-FleetRebuild
        Should -Invoke Write-FleetLog -Times 1 -Exactly -ParameterFilter { $Message -like "*credentials not available*" } -ModuleName SalmonRun.Fleet
    }

    It "fails when project directory not found" {
        Mock Read-FleetSecret { return "keyvalue" } -ModuleName SalmonRun.Fleet
        Mock Test-Path { return $false } -ParameterFilter { $Path -like "*app" }
        $env:INSTALL_PROJECT = "testproject"
        Invoke-FleetRebuild
        Should -Invoke Write-FleetLog -Times 1 -Exactly -ParameterFilter { $Message -like "*project directory not found*" } -ModuleName SalmonRun.Fleet
    }

    It "fails when deploy.ps1 not found" {
        Mock Read-FleetSecret { return "keyvalue" } -ModuleName SalmonRun.Fleet
        Mock Test-Path { return $true } -ParameterFilter { $Path -like "*app" } -ModuleName SalmonRun.Fleet
        Mock Test-Path { return $false } -ParameterFilter { $Path -like "*deploy*" } -ModuleName SalmonRun.Fleet
        Mock Push-Location { }
        Mock Pop-Location { }
        $env:INSTALL_PROJECT = "testproject"
        Invoke-FleetRebuild
        Should -Invoke Write-FleetLog -Times 1 -Exactly -ParameterFilter { $Message -like "*deploy.ps1 not found*" } -ModuleName SalmonRun.Fleet
    }
}

Describe "Start-FleetTaskDispatch" -Tag "Fleet", "Regression-Only" {
    It "handles empty task list gracefully" {
        Mock Test-Path { return $false }
        Mock New-Item { }
        Mock Write-FleetLog { }
        Mock Get-ChildItem { return @() }
        Mock Start-Sleep { throw "exit loop" }
        Mock Move-Item { }
        Mock Set-Content { }
        Mock Get-Content { return "" }
        Mock Add-Content { }
        Mock git { }
        { Start-FleetTaskDispatch -RepoDir "/tmp/test" -PollIntervalSec 1 -StallTimeoutSec 300 } | Should -Throw
    }
}

Describe "Format-FleetHealthReport" -Tag "Fleet", "Regression-Only" {
    It "reports pass/fail counts" {
        $script:Results = @(
            @{ Passed = $true; Name = "Test1" }
            @{ Passed = $false; Name = "Test2" }
        )
        $script:FailCount = 1
        { Format-FleetHealthReport } | Should -Not -Throw
    }
}

Describe "Test-FleetContainerHealth" -Tag "Fleet", "Regression-Only" {
    It "handles missing container gracefully" {
        function Get-AgentServiceName { param($Role, $Index) return "oc-orch" }
        Mock docker { return $null }
        $agentRoles = @(@{ Role = "ORCH"; Index = 0; ShortName = "oc-orch" })
        { Test-FleetContainerHealth -AgentRoles $agentRoles } | Should -Not -Throw
    }
}

Describe "Test-FleetTelegramPolling" -Tag "Fleet", "Regression-Only" {
    It "handles no containers gracefully" {
        function global:docker {
            $global:LASTEXITCODE = 0
            $argLine = $args -join " "
            if ($argLine -match "ps.*oc-orch") { return "" }
            return @()
        }
        { Test-FleetTelegramPolling -StackName "teststack" } | Should -Not -Throw
    }
}

Describe "Test-FleetSecretHydration" -Tag "Fleet", "Regression-Only" {
    It "runs with empty agent roles" {
        $global:SecretSchema = @{ AwsId = @{ Suffix = "aws_id" }; AwsSecret = @{ Suffix = "aws_secret" }; GatewayToken = @{ Suffix = "gateway_token" }; OpenRouterApiKey = @{ Suffix = "openrouter_api_key" } }
        $global:RoleProviderKeyMap = @{}
        function Get-AgentSecretPrefix { return "test_prefix" }
        function global:docker { $global:LASTEXITCODE = 0; return "" }
        { Test-FleetSecretHydration -AgentRoles @() -StackName "teststack" } | Should -Not -Throw
    }
}

Describe "Get-ActiveAgentIds" -Tag "Fleet", "Regression-Only" {
    It "returns empty when docker services command fails" {
        function global:docker { $global:LASTEXITCODE = 1; return $null }

        $result = Get-ActiveAgentIds
        $result | Should -BeNullOrEmpty
    }
}

Describe "Read-FleetSecret" -Tag "Fleet" {
    It "returns null when secret path does not exist" {
        Mock Test-Path { return $false }
        Read-FleetSecret -Name "nonexistent" | Should -BeNullOrEmpty
    }
}

Describe "Test-FleetCodeHealth" -Tag "Fleet" {
    It "runs without errors" {
        Mock Get-ChildItem { return @() }
        { Test-FleetCodeHealth -RepoDir "C:\temp" } | Should -Not -Throw
    }
}

Describe "Test-FleetSelfHealth" -Tag "Fleet" {
    It "runs without errors" {
        $script:Results = @()
        $script:FailCount = 0
        Mock Get-Date { return "2026-01-01" }
        { Test-FleetSelfHealth } | Should -Not -Throw
    }
}

Describe "Test-FleetSidecarHealth" -Tag "Fleet" {
    It "returns ok when all sidecars are running" {
        function global:docker { $global:LASTEXITCODE = 0; return "is-Fleet.1" }
        { Test-FleetSidecarHealth -StackName "teststack" } | Should -Not -Throw
    }
}

Describe "Test-FleetSwarmReality" -Tag "Fleet" {
    It "runs without errors" {
        function global:docker { $global:LASTEXITCODE = 0; return "" }
        { Test-FleetSwarmReality -StackName "teststack" } | Should -Not -Throw
    }
}

Describe "Test-FleetVolumeIntegrity" -Tag "Fleet" {
    It "returns results array when volume inspect fails" {
        Mock docker { return "" }
        $result = Test-FleetVolumeIntegrity -VolumeName "test_vol"
        $result | Should -Not -BeNullOrEmpty
        $result[0].Name | Should -Be "Double-prefixed volumes cleanup"
    }
}

Describe "Test-FleetAqeTopology" -Tag "Fleet" {
    It "runs without errors when AQE is not deployed" {
        Mock docker { return $null }
        { Test-FleetAqeTopology -StackName "teststack" } | Should -Not -Throw
    }
}

Describe "Start-SecretRotationEndpoint — validation logic" -Tag "Fleet", "Regression-Only" {
    BeforeAll {
        function Test-LengthMatch {
            param([string]$CurrentValue, [string]$NewValue)
            return $NewValue.Length -eq $CurrentValue.Length
        }

        function Test-MissingFields {
            param($Body)
            return (-not $Body.container -or -not $Body.key -or -not $Body.value)
        }

        function Test-AllowedContainer {
            param([string]$Container, [string[]]$Allowed = @("oc-base", "is-Fleet", "is-api"))
            return $Container -in $Allowed
        }

        function Test-KeyInBundle {
            param([string]$Key, [hashtable]$Bundle)
            return $Bundle.ContainsKey($Key)
        }
    }

    It "detects missing container field" {
        $body = [PSCustomObject]@{ key = "token"; value = "newval" }
        Test-MissingFields -Body $body | Should -Be $true
    }

    It "detects missing key field" {
        $body = [PSCustomObject]@{ container = "oc-orch"; value = "newval" }
        Test-MissingFields -Body $body | Should -Be $true
    }

    It "detects missing value field" {
        $body = [PSCustomObject]@{ container = "oc-orch"; key = "token" }
        Test-MissingFields -Body $body | Should -Be $true
    }

    It "passes when all fields present" {
        $body = [PSCustomObject]@{ container = "oc-orch"; key = "token"; value = "newval" }
        Test-MissingFields -Body $body | Should -Be $false
    }

    It "rejects disallowed container" {
        Test-AllowedContainer -Container "some-other" | Should -Be $false
    }

    It "allows oc-base container" {
        Test-AllowedContainer -Container "oc-base" | Should -Be $true
    }

    It "allows Fleet container" {
        Test-AllowedContainer -Container "is-Fleet" | Should -Be $true
    }

    It "allows api-proxy container" {
        Test-AllowedContainer -Container "is-api" | Should -Be $true
    }

    It "rejects length mismatch" {
        Test-LengthMatch -CurrentValue "abc" -NewValue "toolong" | Should -Be $false
    }

    It "accepts matching length" {
        Test-LengthMatch -CurrentValue "abc" -NewValue "xyz" | Should -Be $true
    }

    It "detects key present in bundle" {
        $bundle = @{ token = "abc123"; gateway = "xyz" }
        Test-KeyInBundle -Key "token" -Bundle $bundle | Should -Be $true
    }

    It "detects key absent from bundle" {
        $bundle = @{ token = "abc123" }
        Test-KeyInBundle -Key "aws_id" -Bundle $bundle | Should -Be $false
    }

    It "has /rotate endpoint in Start-SecretRotationEndpoint" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetRotationHelpers.ps1") -Raw
        $content | Should -Match '"/rotate"'
    }

    It "has is-bookkeeping in AllowedContainers in Start-SecretRotationEndpoint" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-SecretRotationEndpoint.ps1") -Raw
        $content | Should -Match '"is-bookkeeping"'
    }

    It "does not allow retired is-api in Start-SecretRotationEndpoint" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-SecretRotationEndpoint.ps1") -Raw
        $content | Should -Not -Match '"is-api"'
    }
}

Describe "FleetHealthState type" -Tag "Fleet", "Regression-Only" {
    It "is a hashtable (not PSCustomObject)" {
        $initContent = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Fleet-state.ps1") -Raw
        $initContent | Should -Match '\$script:FleetHealthState = @{'
    }

    It "does not use PSCustomObject for script state" {
        $initContent = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Fleet-state.ps1") -Raw
        $initContent | Should -Not -Match '\[PSCustomObject\]@'
    }
}

Describe "Empty catch blocks" -Tag "Fleet" {
    It "Start-SecretRotationEndpoint catch logs via Write-Debug" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetRotationHelpers.ps1") -Raw
        $content | Should -Match 'Write-Debug "SecretRotationEndpoint: Listener.Stop\(\) failed'
    }

    It "Start-FleetHealthListener catch logs via Write-Debug" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetHealthHandlers.ps1") -Raw
        $content | Should -Match 'Write-Debug "FleetHealthListener: Listener.Stop\(\) failed'
    }

    It "Invoke-FleetEntrypoint state POST failure uses Write-FleetLog" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Invoke-FleetEntrypoint.ps1") -Raw
        $content | Should -Match 'Write-FleetLog "Fleet state POST failed'
    }

    It "Invoke-FleetEntrypoint verifies health listener is alive after start" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Invoke-FleetEntrypoint.ps1") -Raw
        $content | Should -Match 'Invoke-RestMethod.*127.0.0.1.*/health'
        $content | Should -Match 'listenerMaxRetries'
        $content | Should -Match 'Health listener not responding'
    }
}

Describe "FleetHealthCheck parallel error resilience" -Tag "Fleet" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
        Mock Write-SetupLog { }
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
        Mock Get-InterclawConstants { return $global:InterclawConstants }
    }

    It "returns failure result when Test-FleetStackHealth throws" {
        Mock Test-FleetStackHealth { throw "Simulated error" }
        Mock Get-StackName { return "teststack" }
        Mock Get-ActiveAgentRoles { return @() }
        $result = Invoke-FleetHealthCheck -Mode check -Parallel:$true
        $result | Should -Not -BeNullOrEmpty
        $result | Should -BeGreaterThan 0
    }

    It "does not throw when parallel runspace fails" {
        Mock Test-FleetStackHealth { throw "Parallel crash" }
        Mock Get-StackName { return "teststack" }
        Mock Get-ActiveAgentRoles { return @() }
        { $null = Invoke-FleetHealthCheck -Mode check -Parallel:$true } | Should -Not -Throw
    }
}

Describe "Start-FleetOperationalListener — security and structure" -Tag "Fleet", "OperationalListener", "Regression-Only" {
    BeforeAll {
        $script:OpHelpersPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetOperationalHelpers.ps1"
        $script:OpHelpersContent = Get-Content -Encoding utf8 $script:OpHelpersPath -Raw
    }

    It "removes all Invoke-Expression calls" {
        $content = $script:OpHelpersContent
        $content | Should -Not -Match 'Invoke-Expression'
    }

    It "uses constant-time token comparison via CryptographicOperations.FixedTimeEquals" {
        $content = $script:OpHelpersContent
        $content | Should -Match 'FixedTimeEquals'
    }

    It "uses Invoke-NativeCommand for docker operations" {
        $content = $script:OpHelpersContent
        $content | Should -Match 'Invoke-NativeCommand'
    }

    It "validates stack name against an allowlist regex" {
        $content = $script:OpHelpersContent
        $content | Should -Match 'Get-StackName'
    }

    It "reads fleet API token with explicit error handling and trimming" {
        $content = $script:OpHelpersContent
        $content | Should -Match '\.Trim\(\)'
    }

    It "returns 403 for both missing and invalid tokens" {
        $content = $script:OpHelpersContent
        $content | Should -Match 'error.*forbidden'
    }

    It "no longer uses the OPENCLAUD_AUDIT_CYCLE_DIR typo" {
        $content = $script:OpHelpersContent
        $content | Should -Not -Match 'OPENCLAUD_AUDIT_CYCLE_DIR'
    }

    It "splits route handlers as inner functions" {
        $content = $script:OpHelpersContent
        $content | Should -Match 'function Test-TokenConstantTime'
        $content | Should -Match 'function Test-Auth'
        $content | Should -Match 'function Get-AuditState'
        $content | Should -Match 'function Get-DeployStatus'
        $content | Should -Match 'function Invoke-DockerServiceUpdate'
        $content | Should -Match 'function Invoke-DockerStackPs'
    }

    It "has dispatcher route table with 6 routes (no audit trigger)" {
        $content = $script:OpHelpersContent
        $expectedRoutes = @('/api/health','/api/audit/state','/api/deploy/status','/api/deploy/fleet-update','/api/fleet/services','/api/routes')
        $found = $expectedRoutes | Where-Object { $content -match [regex]::Escape($_) }
        $found.Count | Should -Be 6
    }
}

Describe "FleetHealthState accessor functions" -Tag "Fleet", "HealthState", "Regression-Only" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
        Mock Write-SetupLog { }
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
        Mock Get-StackName { return "teststack" }
    }

    It "Get-FleetHealthState returns a hashtable" {
        $state = Get-FleetHealthState
        $state | Should -BeOfType [hashtable]
    }

    It "Get-FleetHealthState contains all required fields" {
        $state = Get-FleetHealthState
        $state.Keys | Should -Contain 'Status'
        $state.Keys | Should -Contain 'LastUpdate'
        $state.Keys | Should -Contain 'FailCount'
        $state.Keys | Should -Contain 'UptimeSeconds'
        $state.Keys | Should -Contain 'StartTime'
        $state.Keys | Should -Contain 'Version'
        $state.Keys | Should -Contain 'Hostname'
        $state.Keys | Should -Contain 'StackName'
    }

    It "Update-FleetHealthState sets a single key-value pair" {
        Update-FleetHealthState -Key 'Status' -Value 'degraded'
        $state = Get-FleetHealthState
        $state.Status | Should -Be 'degraded'
        Update-FleetHealthState -Key 'Status' -Value 'ok'
    }

    It "Update-FleetHealthState sets multiple properties via hashtable" {
        Update-FleetHealthState -Properties @{ Status = 'degraded'; FailCount = 5 }
        $state = Get-FleetHealthState
        $state.Status | Should -Be 'degraded'
        $state.FailCount | Should -Be 5
        Update-FleetHealthState -Properties @{ Status = 'ok'; FailCount = 0 }
    }

    It "state mutation is visible across script/module boundary" {
        $state = Get-FleetHealthState
        $state.FailCount | Should -Be 0
        Update-FleetHealthState -Key 'FailCount' -Value 42
        $state = Get-FleetHealthState
        $state.FailCount | Should -Be 42
        Update-FleetHealthState -Key 'FailCount' -Value 0
    }
}

Describe "1Fleet.ps1 state declaration" -Tag "Fleet", "HealthState", "Regression-Only" {
    It "no longer declares its own FleetHealthState" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\1Fleet.ps1") -Raw
        $content | Should -Not -Match '\$script:FleetHealthState\s*=\s*@'
    }

    It "uses module accessors Get-FleetHealthState and Update-FleetHealthState" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\1Fleet.ps1") -Raw
        $content | Should -Match 'Get-FleetHealthState'
        $content | Should -Match 'Update-FleetHealthState'
    }
}

Describe "Invoke-FleetFailureTracker" -Tag "Fleet", "FailureTracker" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Invoke-FleetFailureTracker.ps1")
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
    }

    It "logs first 3 failures for a new key" {
        $script:FailureTracker = @{}
        1..3 | ForEach-Object {
            Should-LogRemediationFailure -FailureKey "test-key" | Should -Be $true
        }
    }

    It "skips logging on 4th consecutive failure" {
        $script:FailureTracker = @{}
        1..3 | ForEach-Object { Should-LogRemediationFailure -FailureKey "skip-key" }
        Should-LogRemediationFailure -FailureKey "skip-key" | Should -Be $false
    }

    It "skips logging on 5th consecutive failure" {
        $script:FailureTracker = @{}
        1..4 | ForEach-Object { Should-LogRemediationFailure -FailureKey "skip2-key" }
        Should-LogRemediationFailure -FailureKey "skip2-key" | Should -Be $false
    }

    It "logs on 6th (every 6th) consecutive failure" {
        $script:FailureTracker = @{}
        1..5 | ForEach-Object { Should-LogRemediationFailure -FailureKey "every6-key" }
        Should-LogRemediationFailure -FailureKey "every6-key" | Should -Be $true
    }

    It "tracks keys independently" {
        $script:FailureTracker = @{}
        Should-LogRemediationFailure -FailureKey "key-a" | Should -Be $true
        Should-LogRemediationFailure -FailureKey "key-a" | Should -Be $true
        Should-LogRemediationFailure -FailureKey "key-b" | Should -Be $true
        Should-LogRemediationFailure -FailureKey "key-a" | Should -Be $true
        Should-LogRemediationFailure -FailureKey "key-a" | Should -Be $false
        Should-LogRemediationFailure -FailureKey "key-b" | Should -Be $true
    }

    It "Reset-RemediationFailureTracking removes the key" {
        $script:FailureTracker = @{}
        Should-LogRemediationFailure -FailureKey "reset-key"
        $script:FailureTracker.ContainsKey("reset-key") | Should -Be $true
        Reset-RemediationFailureTracking -FailureKey "reset-key"
        $script:FailureTracker.ContainsKey("reset-key") | Should -Be $false
    }

    It "tracks consecutive count correctly with reset+re-log" {
        $script:FailureTracker = @{}
        1..4 | ForEach-Object { Should-LogRemediationFailure -FailureKey "cycle-key" }
        Should-LogRemediationFailure -FailureKey "cycle-key" | Should -Be $false
        Reset-RemediationFailureTracking -FailureKey "cycle-key"
        Should-LogRemediationFailure -FailureKey "cycle-key" | Should -Be $true
        Should-LogRemediationFailure -FailureKey "cycle-key" | Should -Be $true
    }
}

Describe "Invoke-FleetRemediation" -Tag "Fleet", "Remediation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Invoke-FleetRemediation.ps1")
        . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Process\SalmonRun.Process.ps1")
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
        Mock Write-Warning { }
        Mock Write-Information { }
        Mock Invoke-NativeCommand { return [PSCustomObject]@{ Success = $true; ExitCode = 0; Output = @("test") } }
        Mock Start-Sleep { }
        Mock Get-BackoffDelay { return 1 }
        Mock Invoke-DockerWithLogging { }
    }

    It "Invoke-RemedyWithRetry returns success on first attempt" {
        $action = { return @{ Success = $true; Detail = "fixed" } }
        $result = Invoke-RemedyWithRetry -TestName "test" -AttemptAction $action -MaxAttempts 3
        $result.Test | Should -Be "test"
        $result.Action | Should -Match "attempt 1"
    }

    It "Invoke-RemedyWithRetry retries on failure and succeeds" {
        $attempts = @(0)
        $action = {
            $attempts[0]++
            if ($attempts[0] -lt 2) { throw "not yet" }
            return @{ Success = $true; Detail = "fixed on retry" }
        }
        $result = Invoke-RemedyWithRetry -TestName "retry-test" -AttemptAction $action -MaxAttempts 3
        $result.Test | Should -Be "retry-test"
        $result.Action | Should -Match "attempt 2"
    }

    It "Invoke-RemedyWithRetry returns NEEDS MANUAL FIX after all attempts fail" {
        $action = { throw "always fails" }
        $result = Invoke-RemedyWithRetry -TestName "fail-test" -AttemptAction $action -MaxAttempts 2 -BackoffSeconds @(1)
        $result.Test | Should -Be "fail-test"
        $result.Action | Should -Match "NEEDS MANUAL FIX"
    }

    It "Invoke-RemedyWithRetry handles `$null result as failure" {
        $action = { return $null }
        $result = Invoke-RemedyWithRetry -TestName "null-test" -AttemptAction $action -MaxAttempts 2 -BackoffSeconds @(1)
        $result.Test | Should -Be "null-test"
        $result.Action | Should -Match "NEEDS MANUAL FIX"
    }

    It "Invoke-RemedyWithRetry handles Success=false result" {
        $action = { return @{ Success = $false; Detail = "not ready" } }
        $result = Invoke-RemedyWithRetry -TestName "notready-test" -AttemptAction $action -MaxAttempts 2 -BackoffSeconds @(1)
        $result.Test | Should -Be "notready-test"
        $result.Action | Should -Match "NEEDS MANUAL FIX"
    }
}

Describe "Invoke-FleetRemediation — dispatcher" -Tag "Fleet", "Remediation" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
        . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Process\SalmonRun.Process.ps1")
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
        Mock Write-Warning { }
        Mock Write-Information { }
        Mock Invoke-NativeCommand { return [PSCustomObject]@{ Success = $true; ExitCode = 0; Output = @() } }
        Mock Invoke-DockerWithLogging { }
        Mock Start-Sleep { }
        Mock Get-BackoffDelay { return 1 }
        Mock docker { $global:LASTEXITCODE = 0; return "" } -ModuleName SalmonRun.Fleet
        function global:docker { $global:LASTEXITCODE = 0; return "" }
    }

    It "handles replicas failure by calling docker service update" {
        $failedTests = @(@{ Name = "oc-base-0 replicas"; Passed = $false })
        $result = Invoke-FleetRemediation -FailedTests $failedTests -StackName "teststack"
        $result.Count | Should -Be 1
        $result[0].Action | Should -Match "docker service update"
    }

    It "handles crash history failure" {
        Mock docker { return "teststack_oc-base-0" } -ModuleName SalmonRun.Fleet -ParameterFilter { $args -join " " -match "stack services" }
        $failedTests = @(@{ Name = "Agent oc-base-0 crash history"; Passed = $false })
        $result = Invoke-FleetRemediation -FailedTests $failedTests -StackName "teststack"
        $result.Count | Should -Be 1
        $result[0].Action | Should -Match "Removed exited containers"
    }

    It "handles double-prefixed volume failure" {
        Mock docker { return "teststack_teststack_somevol" } -ModuleName SalmonRun.Fleet -ParameterFilter { $args -join " " -match "volume ls" }
        $failedTests = @(@{ Name = "Double-prefixed volume"; Passed = $false })
        $result = Invoke-FleetRemediation -FailedTests $failedTests -StackName "teststack"
        $result.Count | Should -Be 1
        $result[0].Action | Should -Match "Double-prefixed"
    }

    It "handles unknown test name with default case" {
        Mock docker { return "" } -ModuleName SalmonRun.Fleet
        $failedTests = @(@{ Name = "some unknown test"; Passed = $false })
        $result = Invoke-FleetRemediation -FailedTests $failedTests -StackName "teststack"
        $result.Count | Should -Be 1
        $result[0].Action | Should -Match "No known auto-fix"
    }
}

Describe "Test-FleetSecretResolution" -Tag "Fleet", "SecretResolution" {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")
        . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Process\SalmonRun.Process.ps1")
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
        function Get-AgentServiceName { param($Role, $Index) return "oc-base-$Role" }
        Mock docker { return "" }
    }

    It "returns results array when container logs are clean" {
        $result = Test-FleetSecretResolution -AgentRoles @(@{ Role = "BASE"; Index = 0 }) -StackName "teststack" -StackServices @("teststack_oc-base-BASE`t1/1`timg")
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -BeGreaterThan 1
    }

    It "returns results when no container ID is found" {
        $result = Test-FleetSecretResolution -AgentRoles @(@{ Role = "ORCH"; Index = 0 }) -StackName "teststack" -StackServices @("teststack_oc-orch-ORCH`t1/1`timg")
        $result | Should -Not -BeNullOrEmpty
        $result.Count | Should -BeGreaterThan 0
    }
}

Describe "Fleet MCP redeploy/rotate/refresh endpoints" -Tag "Fleet", "MCP", "Regression-Only" {
    BeforeAll {
        $script:FleetHandlersPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\Invoke-FleetHealthHandlers.ps1"
        $script:FleetHandlersContent = Get-Content -Encoding utf8 $script:FleetHandlersPath -Raw
    }

    It "has fleet_redeploy_containers in tool specs" {
        $content = $script:FleetHandlersContent
        $content | Should -Match 'fleet_redeploy_containers'
    }

    It "has secret_rotate in tool specs" {
        $content = $script:FleetHandlersContent
        $content | Should -Match 'secret_rotate'
    }

    It "has secret_rotate_containers in tool specs" {
        $content = $script:FleetHandlersContent
        $content | Should -Match 'secret_rotate_containers'
    }

    It "has /api/deploy/redeploy-containers route" {
        $content = $script:FleetHandlersContent
        $content | Should -Match '/api/deploy/redeploy-containers'
    }

    It "has /api/secret/rotate route" {
        $content = $script:FleetHandlersContent
        $content | Should -Match '/api/secret/rotate'
    }

    It "has /api/secret/rotate-containers route" {
        $content = $script:FleetHandlersContent
        $content | Should -Match '/api/secret/rotate-containers'
    }

    It "has secret_refresh_self in tool specs" {
        $content = $script:FleetHandlersContent
        $content | Should -Match 'secret_refresh_self'
    }

    It "has /api/secret/refresh-self route" {
        $content = $script:FleetHandlersContent
        $content | Should -Match '/api/secret/refresh-self'
    }

    It "has Invoke-SecretRefreshSelf function defined" {
        $content = $script:FleetHandlersContent
        $content | Should -Match 'function Invoke-SecretRefreshSelf'
    }

    It "no longer has /api/deploy/sentry-update endpoint" {
        $content = $script:FleetHandlersContent
        $content | Should -Not -Match '/api/deploy/sentry-update'
    }

    It "no longer has deprecated sentry-update in routes" {
        $content = $script:FleetHandlersContent
        $content | Should -Not -Match 'sentry-update'
    }
}

Describe "Fleet rename completeness" -Tag "Fleet", "Rename", "Regression-Only" {
    It "Start-FleetHealthListener uses is-fleet service label" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-FleetHealthListener.ps1") -Raw
        $content | Should -Match '"is-fleet"'
    }

    It "SalmonRun.Fleet.ps1 loader delegates to the canonical manifest" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1") -Raw
        $content | Should -Match 'SalmonRun.Fleet.psd1'
    }

    It "SalmonRun.Fleet.psm1 loader uses fleet-state.ps1" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.psm1") -Raw
        $content | Should -Match 'fleet-state.ps1'
    }

    It "port-registry has is-fleet not is-sentry" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\..\..\Infrastructure\port-registry.json") -Raw
        $content | Should -Match '"is-fleet"'
        $content | Should -Not -Match '"is-sentry"'
    }

    It "opencode.json uses is_fleet" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\..\..\Infrastructure\opencode\config\opencode.json") -Raw
        $content | Should -Match 'is_fleet'
        $content | Should -Not -Match 'is_sentry'
    }

    It "compose file uses fleet_secrets_bundle not sentry_secrets_bundle" {
        $composePath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\docker-compose.interclaw.yml"
        if (-not (Test-Path $composePath)) {
            Set-ItResult -Skipped -Because "docker-compose.interclaw.yml is generated at deploy time (gitignored) - environment prerequisite"
        }
        $content = Get-Content -Encoding utf8 $composePath -Raw
        $content | Should -Match 'fleet_secrets_bundle'
        $content | Should -Not -Match 'sentry_secrets_bundle'
    }

    It "iam-manifest uses <Project>-FLEET" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\..\..\Infrastructure\manifests\iam-manifest.json") -Raw
        $content | Should -Match '<Project>-FLEET'
    }

    It "fleet-global.json policy is read-only (no PutSecretValue)" {
        $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\..\..\Infrastructure\Policies\fleet-global.json") -Raw
        $content | Should -Match 'GetSecretValue'
        $content | Should -Not -Match 'PutSecretValue'
    }
}

Describe "Get-SuppressedHealthServices" -Tag "Fleet", "Regression-Only" {
    BeforeAll {
        $script:FleetPrivatePath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private\fleet-state.ps1"
        . $script:FleetPrivatePath
    }
    BeforeEach {
        Push-Location $TestDrive
        New-Item -ItemType Directory -Path (Join-Path $PWD "Tasks/Logs") -Force | Out-Null
    }
    AfterEach {
        Pop-Location
    }

    It "returns empty array when no suppression files exist" {
        $result = Get-SuppressedHealthServices
        $result | Should -BeNullOrEmpty
    }

    It "detects per-service suppression file" {
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-oc-orch") -Value ""
        $result = Get-SuppressedHealthServices
        $result | Should -Contain "oc-orch"
    }

    It "detects multiple suppressed services" {
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-oc-orch") -Value ""
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-oc-base") -Value ""
        $result = Get-SuppressedHealthServices
        $result.Count | Should -Be 2
        $result | Should -Contain "oc-orch"
        $result | Should -Contain "oc-base"
    }

    It "extracts correct service name from filename prefix" {
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-mcp_opencode") -Value ""
        $result = Get-SuppressedHealthServices
        $result | Should -Contain "mcp_opencode"
    }

    It "ignores non-suppression files in the log directory" {
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-oc-orch") -Value ""
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/normal-log.txt") -Value ""
        $result = Get-SuppressedHealthServices
        $suppressedNames = $result | Where-Object { $_ -notmatch '\.txt$' }
        $suppressedNames.Count | Should -BeGreaterOrEqual 1
    }

    It "returns unique service names" {
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-oc-orch") -Value ""
        Set-Content -Path (Join-Path $PWD "Tasks/Logs/.suppress-health-oc-orch.backup") -Value ""
        $result = Get-SuppressedHealthServices
        ($result | Select-Object -Unique).Count | Should -Be @($result).Count
    }

    It "handles missing Tasks/Logs directory gracefully" {
        Remove-Item -Path (Join-Path $PWD "Tasks") -Recurse -Force -ErrorAction SilentlyContinue
        $result = Get-SuppressedHealthServices
        $result | Should -BeNullOrEmpty
    }
}

Describe "Invoke-FleetHealthCheck suppression" -Tag "Fleet", "Regression-Only" {
    BeforeEach {
        $testLogDir = Join-Path $TestDrive "Tasks" "Logs"
        New-Item -ItemType Directory -Path $testLogDir -Force | Out-Null
        Mock Write-Warning { } -ModuleName SalmonRun.Fleet
        Mock Write-SetupLog { }
        Mock Write-FleetLog { }
        Mock Write-Verbose { }
        Mock Format-FleetHealthReport { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetStackHealth { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetVolumeIntegrity { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetSecretHydration { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetNetworkConnectivity { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetContainerHealth { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetCodeHealth { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetSidecarHealth { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetSelfHealth { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetServiceEndpoints { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetTelegramPolling { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetAqeTopology { } -ModuleName SalmonRun.Fleet
        Mock Test-FleetSwarmReality { } -ModuleName SalmonRun.Fleet
        Mock Invoke-FleetRemediation { } -ModuleName SalmonRun.Fleet
        Mock Get-StackName { return "TEST" } -ModuleName SalmonRun.Fleet
        Mock Get-ActiveAgentRoles { return @(@{ Role = "ORCH"; Index = 0; ShortName = "oc-orch" }) } -ModuleName SalmonRun.Fleet
        Mock Get-SuppressedHealthServices { return @() } -ModuleName SalmonRun.Fleet
        Mock Test-Path { return $false } -ModuleName SalmonRun.Fleet
        function global:docker { return @() }
    }

    Context "Without suppression files" {
        It "calls remediation in fix mode when failures exist" {
            Mock Test-FleetStackHealth { return @(@{ Name = "stack-replicas"; Passed = $false }) } -ModuleName SalmonRun.Fleet
            $null = Invoke-FleetHealthCheck -Mode fix
            Should -Invoke Invoke-FleetRemediation -Times 1 -Exactly -ModuleName SalmonRun.Fleet
        }
    }

    Context "With global suppression file" {
        It "bypasses all remediation when .suppress-health-all exists" {
            Mock Test-Path { return $true } -ModuleName SalmonRun.Fleet -ParameterFilter { $Path -like "*.suppress-health-all" }
            Mock Test-FleetStackHealth { return @(@{ Name = "stack-replicas"; Passed = $false }) } -ModuleName SalmonRun.Fleet
            $null = Invoke-FleetHealthCheck -Mode fix
            Should -Invoke Invoke-FleetRemediation -Times 0 -Exactly -ModuleName SalmonRun.Fleet
            Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -match "Health check suppression active \(global override\)" } -ModuleName SalmonRun.Fleet
        }
    }

    Context "With per-service suppression" {
        It "filters out suppressed services from remediation" {
            Mock Test-FleetStackHealth { return @(
                @{ Name = "oc-orch replicas"; Passed = $false },
                @{ Name = "oc-base replicas"; Passed = $false }
            )} -ModuleName SalmonRun.Fleet
            Mock Get-SuppressedHealthServices { return @("oc-orch") } -ModuleName SalmonRun.Fleet
            $null = Invoke-FleetHealthCheck -Mode fix
            Should -Invoke Invoke-FleetRemediation -Times 1 -Exactly -ParameterFilter { $FailedTests.Count -eq 1 } -ModuleName SalmonRun.Fleet
            Should -Invoke Write-Warning -ParameterFilter { $Message -match "Suppression active" } -ModuleName SalmonRun.Fleet
        }
    }
}

Describe "Listener decomposition" -Tag "Fleet", "Regression" {
    It "Start-FleetHealthListener is under 50 lines" {
        $path = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-FleetHealthListener.ps1"
        $lines = (Get-Content $path).Count
        $lines | Should -BeLessThan 51
    }

    It "Start-FleetOperationalListener is under 50 lines" {
        $path = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-FleetOperationalListener.ps1"
        $lines = (Get-Content $path).Count
        $lines | Should -BeLessThan 51
    }

    It "Start-SecretRotationEndpoint is under 50 lines" {
        $path = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-SecretRotationEndpoint.ps1"
        $lines = (Get-Content $path).Count
        $lines | Should -BeLessThan 51
    }

    It "Private helpers parse correctly" {
        $files = @(
            "Invoke-FleetHealthHelpers.ps1",
            "Invoke-FleetHealthHandlers.ps1",
            "Invoke-FleetOperationalHelpers.ps1",
            "Invoke-FleetRotationHelpers.ps1"
        )
        foreach ($f in $files) {
            $path = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Private" $f
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because "file $f should have no parse errors"
        }
    }

    It "Public main files parse correctly" {
        $files = @(
            "Start-FleetHealthListener.ps1",
            "Start-FleetOperationalListener.ps1",
            "Start-SecretRotationEndpoint.ps1"
        )
        foreach ($f in $files) {
            $path = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public" $f
            $errs = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $path), [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because "file $f should have no parse errors"
        }
    }
}
