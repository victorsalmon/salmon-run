#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $__RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__SalmonModulesDir = Join-Path $__RepoRoot 'Modules'
    $__DockerModulesDir = Join-Path $__RepoRoot 'Modules'

    # Provide stubs for functions the dependency modules call at load time
    function Get-SalmonRunRepoRoot { return $__RepoRoot }
    function Write-SetupLog { param([string]$Message, [string]$Level, [string]$Agent, [string]$Phase) }
    function Read-InstallJson { return $null }

    # Load modules via dot-source (same as production: Core.ps1 dot-sources Ports.ps1)
    $__PathsPs1 = Join-Path $__DockerModulesDir "SalmonRun.Paths" "SalmonRun.Paths.ps1"
    . $__PathsPs1

    $__PortsPs1 = Join-Path $__DockerModulesDir "SalmonRun.Ports" "SalmonRun.Ports.ps1"
    . $__PortsPs1

    $__DiagnosticsPs1 = Join-Path $__DockerModulesDir "SalmonRun.Diagnostics" "SalmonRun.Diagnostics.ps1"
    . $__DiagnosticsPs1

    $__ConstantsPs1 = Join-Path $__SalmonModulesDir "SalmonRun.Constants" "SalmonRun.Constants.ps1"
    . $__ConstantsPs1

    $script:ConstantsPsd1 = Join-Path $__SalmonModulesDir "SalmonRun.Constants" "SalmonRun.Constants.psd1"
}

Describe "Get-SalmonRunConstants" -Tag "Constants", "Regression-Only" {

    It "returns a hashtable" {
        $c = Get-SalmonRunConstants
        $c | Should -BeOfType [hashtable]
    }

    It "contains all expected keys" {
        $c = Get-SalmonRunConstants
        $expectedKeys = @(
            'GatewayPortBase', 'GatewayPortMultiplier',
            'AwsKeyPropagationDelaySec', 'AwsKeyPropagationRetries', 'AwsKeyInitialPropagationWaitSec',
            'HealthCheckMaxRetries', 'HealthCheckRetryIntervalSec',
            'StackCleanupTimeoutSec', 'StackCleanupRetryIntervalSec', 'PostCleanupWaitSec',
            'SentryCommandPollIntervalSec', 'SentryUpdateCycleIntervalSec',
            'SentryRemediationCooldownSec', 'SentryMainLoopIntervalSec',
            'DockerDesktopStartupWaitSec', 'VolumeSeedRetryMs', 'LogTailLines',
            'ComposeHealthCheckIntervalSec', 'ComposeHealthCheckTimeoutSec',
            'ComposeHealthCheckRetries', 'ComposeHealthCheckStartPeriodSec',
            'ComposeNetworkWatchdogIntervalSec', 'ComposeNetworkWatchdogFailThreshold',
            'MaxAgents',
            'FleetApiPort', 'CodeContainerPort', 'CodeServerPort', 'ProxyPort',
            'InterclawImage', 'SentryImage', 'ProxyImage',
            'McpBrowserlessImage'
        )
        foreach ($key in $expectedKeys) {
            $c[$key] | Should -Not -BeNullOrEmpty -Because "key '$key' should be present"
        }
    }

    It "all values are non-null" {
        $c = Get-SalmonRunConstants
        foreach ($key in $c.Keys) {
            $c[$key] | Should -Not -BeNullOrEmpty -Because "value for '$key' should not be null or empty"
        }
    }

    It "numerical constants are positive integers" {
        $c = Get-SalmonRunConstants
        $numericalKeys = @(
            'GatewayPortBase', 'GatewayPortMultiplier',
            'AwsKeyPropagationDelaySec', 'AwsKeyPropagationRetries', 'AwsKeyInitialPropagationWaitSec',
            'HealthCheckMaxRetries', 'HealthCheckRetryIntervalSec',
            'StackCleanupTimeoutSec', 'StackCleanupRetryIntervalSec', 'PostCleanupWaitSec',
            'SentryCommandPollIntervalSec', 'SentryUpdateCycleIntervalSec',
            'SentryRemediationCooldownSec', 'SentryMainLoopIntervalSec',
            'DockerDesktopStartupWaitSec', 'VolumeSeedRetryMs', 'LogTailLines',
            'ComposeHealthCheckIntervalSec', 'ComposeHealthCheckTimeoutSec',
            'ComposeHealthCheckRetries', 'ComposeHealthCheckStartPeriodSec',
            'ComposeNetworkWatchdogIntervalSec', 'ComposeNetworkWatchdogFailThreshold',
            'MaxAgents',
            'FleetApiPort', 'CodeContainerPort', 'CodeServerPort', 'ProxyPort'
        )
        foreach ($key in $numericalKeys) {
            $c[$key] | Should -BeOfType [int] -Because "'$key' should be an integer"
            $c[$key] | Should -BeGreaterThan 0 -Because "'$key' should be positive"
        }
    }

    It "image constants are strings" {
        $c = Get-SalmonRunConstants
        $imageKeys = @('InterclawImage', 'SentryImage', 'ProxyImage', 'McpBrowserlessImage')
        foreach ($key in $imageKeys) {
            $c[$key] | Should -BeOfType [string] -Because "'$key' should be a string"
            $c[$key] | Should -Match ":\w+$" -Because "'$key' should end with a tag"
        }
    }

    It "port constants match port registry" {
        $c = Get-SalmonRunConstants
        $c.FleetApiPort | Should -Be (Get-ServicePort -Service is-fleet)
        # mcp_opencode_health, mcp_opencode_server, is-marketer, aqe, web
        # retired 2026-08-21/2026-08-22 — port constants for those services were
        # removed (aqe 2026-08-21, web 2026-08-22) and are no longer
        # cross-checked against the registry (the registry moved them to the
        # retired section).
    }
}

Describe "Get-NetworkNames" -Tag "Constants", "Regression-Only" {

    It "returns an ordered hashtable" {
        $n = Get-NetworkNames
        $n.GetType().Name | Should -Be "OrderedDictionary"
    }

    It "contains all expected network names" {
        $n = Get-NetworkNames
        $n.Keys.Count | Should -Be 4
        $n['ServiceNet'] | Should -Not -BeNullOrEmpty
        $n['OrchestrationNet'] | Should -Not -BeNullOrEmpty
        $n['ManagementNet'] | Should -Not -BeNullOrEmpty
        $n['FunnelNet'] | Should -Not -BeNullOrEmpty
    }

    It "values match expected Docker network names" {
        $n = Get-NetworkNames
        $n.ServiceNet | Should -Be "service_net"
        $n.OrchestrationNet | Should -Be "orchestration_net"
        $n.ManagementNet | Should -Be "management_net"
        $n.FunnelNet | Should -Be "funnel_net"
    }

    It "keys are in expected order" {
        $n = Get-NetworkNames
        $expectedOrder = @('ServiceNet', 'OrchestrationNet', 'ManagementNet', 'FunnelNet')
        $i = 0
        foreach ($key in $n.Keys) {
            $key | Should -Be $expectedOrder[$i] -Because "key at position $i should be $($expectedOrder[$i])"
            $i++
        }
    }
}

Describe "Get-DefaultRegion" -Tag "Constants", "Regression-Only" {

    It "returns env var value when set for AWS_SECRETS_REGION" {
        $saved = $env:AWS_SECRETS_REGION
        try {
            $env:AWS_SECRETS_REGION = "ca-central-1"
            $r = Get-DefaultRegion -RegionType AWS_SECRETS_REGION
            $r | Should -Be "ca-central-1"
        } finally {
            $env:AWS_SECRETS_REGION = $saved
        }
    }

    It "returns env var value when set for AWS_REGION" {
        $saved = $env:AWS_REGION
        try {
            $env:AWS_REGION = "eu-west-1"
            $r = Get-DefaultRegion -RegionType AWS_REGION
            $r | Should -Be "eu-west-1"
        } finally {
            $env:AWS_REGION = $saved
        }
    }

    It "falls back to hardcoded defaults when env var is not set" {
        $savedSecrets = $env:AWS_SECRETS_REGION
        $savedRegion = $env:AWS_REGION
        try {
            Remove-Item Env:\AWS_SECRETS_REGION -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_REGION -ErrorAction SilentlyContinue

            $r1 = Get-DefaultRegion -RegionType AWS_SECRETS_REGION
            $r1 | Should -Be "ca-central-1"

            $r2 = Get-DefaultRegion -RegionType AWS_REGION
            $r2 | Should -Be "us-east-1"
        } finally {
            if ($savedSecrets) { $env:AWS_SECRETS_REGION = $savedSecrets }
            if ($savedRegion) { $env:AWS_REGION = $savedRegion }
        }
    }

    It "accepts only AWS_SECRETS_REGION or AWS_REGION" {
        { Get-DefaultRegion -RegionType "INVALID" } | Should -Throw
    }
}

Describe "Get-CodingKeyPriority" -Tag "Constants", "Regression-Only" {

    It "returns array with two elements" {
        $p = Get-CodingKeyPriority
        $p.Count | Should -Be 2
        $p[0] | Should -BeOfType [string]
    }

    It "returns expected priority order" {
        $p = Get-CodingKeyPriority
        $p[0] | Should -Be "OPENCODE_GO1_KEY"
        $p[1] | Should -Be "OPENCODE_GO5_KEY"
    }
}

Describe "SalmonRun.Core forwarder aliases" -Tag "Constants", "Regression-Only" {

    It "forwarder alias for Get-InterclawConstants resolves to real function" {
        $const = Get-InterclawConstants
        $const | Should -Not -BeNullOrEmpty
        $const['MaxAgents'] | Should -Be 9
    }

    It "forwarder alias for Get-NetworkNames resolves to real function" {
        $net = Get-NetworkNames
        $net | Should -Not -BeNullOrEmpty
        $net['ServiceNet'] | Should -Be "service_net"
    }

    It "forwarder alias for Get-DefaultRegion resolves to real function" {
        $region = Get-DefaultRegion -RegionType AWS_SECRETS_REGION
        $region | Should -Not -BeNullOrEmpty
    }

    It "forwarder alias for Get-CodingKeyPriority resolves to real function" {
        $keys = Get-CodingKeyPriority
        $keys.Count | Should -Be 2
    }
}

Describe "Get-ProjectCode" -Tag "Constants", "Regression-Only" {

    It "returns INSTALL_PROJECT when set" {
        $saved = $env:INSTALL_PROJECT
        try {
            $env:INSTALL_PROJECT = "TESTPROJECT"
            Get-ProjectCode | Should -Be "TESTPROJECT"
        } finally {
            $env:INSTALL_PROJECT = $saved
        }
    }

    It "throws when INSTALL_PROJECT is not set" {
        $saved = $env:INSTALL_PROJECT
        try {
            Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
            { Get-ProjectCode } | Should -Throw "*INSTALL_PROJECT environment variable is not set or empty*"
        } finally {
            $env:INSTALL_PROJECT = $saved
        }
    }

    It "throws when INSTALL_PROJECT is empty" {
        $saved = $env:INSTALL_PROJECT
        try {
            $env:INSTALL_PROJECT = ""
            { Get-ProjectCode } | Should -Throw "*INSTALL_PROJECT environment variable is not set or empty*"
        } finally {
            $env:INSTALL_PROJECT = $saved
        }
    }

    It "throws when INSTALL_PROJECT is whitespace" {
        $saved = $env:INSTALL_PROJECT
        try {
            $env:INSTALL_PROJECT = "   "
            { Get-ProjectCode } | Should -Throw "*INSTALL_PROJECT environment variable is not set or empty*"
        } finally {
            $env:INSTALL_PROJECT = $saved
        }
    }
}

Describe "Get-TaskQueueConfig" -Tag "Constants", "Regression-Only" {

    It "returns a PSCustomObject with expected pond/queue sections" {
        $c = Get-TaskQueueConfig
        $c | Should -BeOfType [PSCustomObject]
        $c.Primary | Should -Contain "Code"
        $c.Primary | Should -Contain "Review"
        $c.Ponds | Should -Not -BeNullOrEmpty
        $c.Ponds.Keys | Should -Contain "Intake"
        $c.Ponds.Keys | Should -Contain "QA"
        $c.Ponds.Keys | Should -Contain "Audit"
        $c.Ponds.Keys | Should -Contain "Archive"
    }

    It "assigns a role to every pond" {
        $c = Get-TaskQueueConfig
        foreach ($key in $c.Ponds.Keys) {
            $c.Ponds[$key].Role | Should -Not -BeNullOrEmpty -Because "pond '$key' should have a role"
        }
    }
}

Describe "SalmonRun.Constants Module Manifest" -Tag "Constants", "Regression-Only" {

    It "exports exactly 6 functions" {
        $manifest = Import-PowerShellDataFile -Path $script:ConstantsPsd1
        $exports = $manifest.FunctionsToExport
        $exports.Count | Should -Be 6
        $exports | Should -Contain "Get-SalmonRunConstants"
        $exports | Should -Contain "Get-NetworkNames"
        $exports | Should -Contain "Get-DefaultRegion"
        $exports | Should -Contain "Get-CodingKeyPriority"
        $exports | Should -Contain "Get-ProjectCode"
        $exports | Should -Contain "Get-TaskQueueConfig"
    }

    It "exports the legacy Get-InterclawConstants alias" {
        $manifest = Import-PowerShellDataFile -Path $script:ConstantsPsd1
        $manifest.AliasesToExport | Should -Contain "Get-InterclawConstants"
    }
}
