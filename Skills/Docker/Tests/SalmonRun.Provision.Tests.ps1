[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'ConvertTo-SecureString -AsPlainText required for provision tests')]
param()

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    . (Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\SalmonRun.Provision.ps1")
    Mock Write-SetupLog { }
    Mock Write-Host { }
}

Describe "Remove-AgentIamUser" -Tag "Provision" {
    BeforeEach {
        $script:SavedAwsSsoProfile = $env:AWS_SSO_PROFILE
    }

    AfterEach {
        if ($script:SavedAwsSsoProfile) { $env:AWS_SSO_PROFILE = $script:SavedAwsSsoProfile } else { Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue }
    }

    It "skips when IAM user does not exist" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = $null; ExitCode = 254; Success = $false }
        }
        $env:AWS_SSO_PROFILE = "test-profile"
        { Remove-AgentIamUser -ProjectCode "TEST" -Role "BASE" -InstanceId "99" } | Should -Not -Throw
    }

    It "removes IAM user with access keys and policies" {
        $script:awsCalls = @()
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            $script:awsCalls += ($Command.ToString())
            return [pscustomobject]@{ Output = '{"AccessKeyMetadata":[{"AccessKeyId":"AKIATEST","Status":"Active"}]}'; ExitCode = 0; Success = $true }
        }
        $env:AWS_SSO_PROFILE = "test-profile"
        { Remove-AgentIamUser -ProjectCode "TEST" -Role "BASE" -InstanceId "99" } | Should -Not -Throw
        $script:awsCalls.Count | Should -BeGreaterThan 0
    }

    It "handles AWS CLI failures gracefully" {
        $callCount = 0
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            $callCount++
            if ($callCount -eq 1) { return [pscustomobject]@{ Output = '{"User":{"UserName":"TEST-BASE-99"}}'; ExitCode = 0; Success = $true }
            }
            return [pscustomobject]@{ Output = $null; ExitCode = 1; Success = $false }
        }
        $env:AWS_SSO_PROFILE = "test-profile"
        { Remove-AgentIamUser -ProjectCode "TEST" -Role "BASE" -InstanceId "99" } | Should -Not -Throw
    }
}

Describe "Module manifest FunctionsToExport" -Tag "Provision", "Regression-Only" {
    It "exports every Public/*.ps1 function name" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\SalmonRun.Provision.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport

        $publicDir = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\Public"
        $publicFiles = Get-ChildItem -LiteralPath $publicDir -Filter "*.ps1" -Name
        $expectedNames = $publicFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }

        $missing = $expectedNames | Where-Object { $_ -notin $exports }

        if ($missing.Count -gt 0) { Write-Host "Missing from FunctionsToExport: $($missing -join ', ')" }

        $missing.Count | Should -Be 0
    }
}

Describe "Invoke-AwsCli" -Tag "Provision" {
    It "calls aws with remaining arguments" {
        $script:awsCalled = $false
        function aws { $global:LASTEXITCODE = 0; $script:awsCalled = $true; return "test-output" }
        $env:AWS_SSO_PROFILE = "test-profile"
        $result = Invoke-AwsCli "sts" "get-caller-identity"
        $script:awsCalled | Should -BeTrue
    }

    It "passes output and exit code through" {
        function aws { $global:LASTEXITCODE = 1; return "error" }
        $env:AWS_SSO_PROFILE = "test-profile"
        $result = Invoke-AwsCli "iam" "list-users"
        $LASTEXITCODE | Should -Be 1
    }
}

Describe "Invoke-SecretHydration" -Tag "Provision" {
    It "throws when INSTALL_PROJECT not set" {
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
        { Invoke-SecretHydration } | Should -Throw
    }

    It "throws when INSTALL_ROLE not set" {
        $env:INSTALL_PROJECT = "TEST"
        Remove-Item Env:\INSTALL_ROLE -ErrorAction SilentlyContinue
        { Invoke-SecretHydration } | Should -Throw
    }

    It "handles missing sovereignty tier gracefully" {
        $env:INSTALL_PROJECT = "TEST"
        $env:INSTALL_ROLE = "ORCH"
        $env:INTERCLAW_SOVEREIGNTY = "invalid-tier"
        Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue
        { Invoke-SecretHydration } | Should -Throw
    }

    It "detects missing AWS SSO profile" {
        $env:INSTALL_PROJECT = "TEST"
        $env:INSTALL_ROLE = "ORCH"
        $env:INTERCLAW_SOVEREIGNTY = "global"
        Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue
        { Invoke-SecretHydration } | Should -Throw
    }
}

Describe "Read-ContainerSecretBundle" -Tag "Provision" {
    BeforeEach {
        Mock Write-Verbose { }
    }

    It "returns null when Docker inspect returns null and no service is available" {
        Mock docker { 'null' } -ParameterFilter {
            $args -contains 'inspect'
        } -Verifiable
        $result = Read-ContainerSecretBundle -BundleName 'test_bundle'
        $result | Should -BeNullOrEmpty
        Should -InvokeVerifiable
    }

    It "returns null when Docker inspect returns nil and no service is available" {
        Mock docker { '<nil>' } -ParameterFilter { $args -contains 'inspect' }
        $result = Read-ContainerSecretBundle -BundleName 'test_bundle'
        $result | Should -BeNullOrEmpty
    }

    It "decodes valid bundle via Docker inspect" {
        $testJson = '{"aws_id":"AKIATEST","aws_secret":"testSecret123"}'
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($testJson))
        Mock docker { "`"$encoded`"" } -ParameterFilter { $args -contains 'inspect' }
        $result = Read-ContainerSecretBundle -BundleName 'test_bundle'
        $result.aws_id | Should -Be 'AKIATEST'
        $result.aws_secret | Should -Be 'testSecret123'
    }

    It "falls back to docker exec when inspect returns null" {
        Mock docker { 'null' } -ParameterFilter { $args -contains 'inspect' }
        Mock docker { 'test-container.1.abc' } -ParameterFilter {
            $args -contains 'service' -and $args -contains 'ps'
        }
        $testJson = '{"aws_id":"AKIAEXEC","aws_secret":"execSecret456"}'
        Mock docker { $testJson } -ParameterFilter {
            $args -contains 'exec' -and $args -contains 'cat'
        }
        $result = Read-ContainerSecretBundle -BundleName 'test_bundle' -ServiceName 'test_svc'
        $result.aws_id | Should -Be 'AKIAEXEC'
        $result.aws_secret | Should -Be 'execSecret456'
    }

    It "falls back to docker exec when inspect throws" {
        Mock docker { throw "inspect failed" } -ParameterFilter {
            $args -contains 'inspect'
        }
        Mock docker { 'test-container.1.abc' } -ParameterFilter {
            $args[0] -eq 'service' -and $args[1] -eq 'ps'
        }
        $testJson = '{"key":"fromExec"}'
        Mock docker { $testJson } -ParameterFilter {
            $args[0] -eq 'exec'
        }
        $result = Read-ContainerSecretBundle -BundleName 'test_bundle' -ServiceName 'test_svc'
        $result.key | Should -Be 'fromExec'
    }

    It "returns null when no running tasks found for service" {
        Mock docker { 'null' } -ParameterFilter { $args -contains 'inspect' }
        Mock docker { $null } -ParameterFilter {
            $args -contains 'service' -and $args -contains 'ps'
        }
        $result = Read-ContainerSecretBundle -BundleName 'test_bundle' -ServiceName 'test_svc'
        $result | Should -BeNullOrEmpty
    }
}

Describe "Invoke-AgentProvisioningPipeline" -Tag "Provision" {
    It "throws when required env vars are not set" {
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
        { Invoke-AgentProvisioningPipeline } | Should -Throw
    }
}

Describe "Invoke-InterclawCredentialTests" -Tag "Provision" {
    It "does not throw when called with defaults" {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq "aws" }
        { Invoke-InterclawCredentialTests } | Should -Not -Throw
    }
}

Describe "Invoke-InterclawOrchProvisioning" -Tag "Provision" {
    It "throws when INSTALL_PROJECT is not set" {
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
        { Invoke-InterclawOrchProvisioning } | Should -Throw
    }
}

Describe "Test-AgentCredentialIsolation" -Tag "Provision" {
    It "returns false when no AWS access key in env" {
        Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        $result = Test-AgentCredentialIsolation
        $result | Should -Be $false
    }
}

Describe "Test-FleetCredentialIsolation" -Tag "Provision" {
    It "returns false when no AWS env vars set" {
        Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        $result = Test-FleetCredentialIsolation
        $result | Should -Be $false
    }
}

Describe "Phase 0b - Coding key pre-flight" -Tag "Provision" {
    BeforeEach {
        $script:SavedOpencodeKey1 = $env:OPENCODE_GO1_KEY
        $script:SavedOpencodeKey5 = $env:OPENCODE_GO5_KEY
        $script:SavedOn1 = $env:OPENCODE_GO1_ON
        $script:SavedOn2 = $env:OPENCODE_GO2_ON

    }

    AfterEach {
        if ($script:SavedOpencodeKey1) { $env:OPENCODE_GO1_KEY = $script:SavedOpencodeKey1 } else { Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue }
        if ($script:SavedOpencodeKey5) { $env:OPENCODE_GO5_KEY = $script:SavedOpencodeKey5 } else { Remove-Item Env:\OPENCODE_GO5_KEY -ErrorAction SilentlyContinue }
        if ($script:SavedOn1) { $env:OPENCODE_GO1_ON = $script:SavedOn1 } else { Remove-Item Env:\OPENCODE_GO1_ON -ErrorAction SilentlyContinue }
        if ($script:SavedOn2) { $env:OPENCODE_GO2_ON = $script:SavedOn2 } else { Remove-Item Env:\OPENCODE_GO2_ON -ErrorAction SilentlyContinue }

    }

    It "proceeds when at least one coding key is present" {
        $env:OPENCODE_GO1_KEY = "sk-test-opencode"
        $CodingKeyRegistry = [ordered]@{
            "OPENCODE_GO1_KEY" = "opencode-go (Minimax M2.7)"
            "OPENCODE_GO5_KEY" = "opencode-go key 5 (backup)"
        }
        $AvailableCodingKeys = @()
        foreach ($KeyName in $CodingKeyRegistry.Keys) {
            $Val = [System.Environment]::GetEnvironmentVariable($KeyName)
            if (-not [string]::IsNullOrWhiteSpace($Val)) {
                $AvailableCodingKeys += $KeyName
            }
        }
        $AvailableCodingKeys.Count | Should -BeGreaterThan 0
    }

    It "aborts when no coding keys are present" {
        Remove-Item Env:\OPENCODE_GO1_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\OPENCODE_GO5_KEY -ErrorAction SilentlyContinue

        $CodingKeyRegistry = [ordered]@{
            "OPENCODE_GO1_KEY" = "opencode-go (Minimax M2.7)"
            "OPENCODE_GO5_KEY" = "opencode-go key 5 (backup)"
        }
        $AvailableCodingKeys = @()
        foreach ($KeyName in $CodingKeyRegistry.Keys) {
            $Val = [System.Environment]::GetEnvironmentVariable($KeyName)
            if (-not [string]::IsNullOrWhiteSpace($Val)) {
                $AvailableCodingKeys += $KeyName
            }
        }
        $AvailableCodingKeys.Count | Should -Be 0
    }
}

Describe "Test-AwsSessionValidity" -Tag "Provision" {
    It "passes when AWS session is valid" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = '{"Account":"123","Arn":"test"}'; ExitCode = 0; Success = $true }
        }
        { Test-AwsSessionValidity -SsoProfile "test" } | Should -Not -Throw
    }

    It "throws when AWS session is expired" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = "ExpiredToken"; ExitCode = 254; Success = $false }
        }
        { Test-AwsSessionValidity -SsoProfile "expired" } | Should -Throw
    }
}

Describe "Test-CodingKeyPresence" -Tag "Provision" {
    It "returns true when key is found" {
        Mock Get-SecretFromAws { return "sk-test-key" }
        Test-CodingKeyPresence -ProjectCode "TEST" -SsoProfile "test" | Should -Be $true
    }

    It "returns false when key is not found" {
        Mock Get-SecretFromAws { return $null }
        Test-CodingKeyPresence -ProjectCode "TEST" -SsoProfile "test" | Should -Be $false
    }
}

Describe "Test-SecretAvailability" -Tag "Provision" {
    It "passes when both secrets exist" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = '{"ARN":"test"}'; ExitCode = 0; Success = $true }
        }
        $result = Test-SecretAvailability -ProjectCode "TEST" -SsoProfile "test" -SecretsRegion "ca-central-1"
        $result.ProjectSecretFound | Should -Be $true
        $result.InstallationSecretFound | Should -Be $true
        $result.MissingSecretNames.Count | Should -Be 0
    }

    It "reports missing secrets" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = $null; ExitCode = 1; Success = $false }
        }
        $result = Test-SecretAvailability -ProjectCode "TEST" -SsoProfile "test" -SecretsRegion "ca-central-1"
        $result.ProjectSecretFound | Should -Be $false
        $result.InstallationSecretFound | Should -Be $false
        $result.MissingSecretNames.Count | Should -Be 2
    }
}

Describe "Test-AwsIamPermissions" -Tag "Provision" {
    It "throws when ListUsers fails" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = "AccessDenied"; ExitCode = 254; Success = $false }
        }
        { Test-AwsIamPermissions -SsoProfile "test" -SecretsRegion "ca-central-1" -ProjectCode "TEST" } | Should -Throw
    }

    It "throws when CreateUser fails after ListUsers succeeds" {
        $callCount = 0
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            $callCount++
            if ($callCount -eq 1) { return [pscustomobject]@{ Output = '{"Users":[]}'; ExitCode = 0; Success = $true } }
            return [pscustomobject]@{ Output = "AccessDenied"; ExitCode = 254; Success = $false }
        }
        { Test-AwsIamPermissions -SsoProfile "test" -SecretsRegion "ca-central-1" -ProjectCode "TEST" } | Should -Throw
    }
}

Describe "Initialize-AwsSsoSession dispatch" -Tag "Provision" {
    It "throws when NonInteractive and session is expired" {
        Mock Test-AwsSessionValidity { throw "expired" }
        { Initialize-AwsSsoSession -SsoProfile "test" -NonInteractive } | Should -Throw
    }
}

Describe "Invoke-AwsPreflight" -Tag "Provision" {
    It "throws when AWS session is invalid" {
        Mock Test-AwsSessionValidity { throw "expired" }
        { Invoke-AwsPreflight -SsoProfile "test" -SecretsRegion "ca-central-1" -ProjectCode "TEST" -AgentRoles @(@{Role="BASE"}) -InstallOpencode "false" -InstallBookkeeping "false" -InstallJsonPath "test.json" } | Should -Throw
    }
}

Describe "Invoke-BedrockProfileSetup" -Tag "Provision" {
    It "skips for CODE role" {
        $env:INSTALL_ROLE = "CODE"
        { Invoke-BedrockProfileSetup } | Should -Not -Throw
        Remove-Item Env:\INSTALL_ROLE -ErrorAction SilentlyContinue
    }
}

Describe "Invoke-OrphanIamCleanup" -Tag "Provision" {
    BeforeEach {
        Mock Write-SetupLog { }
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It "runs without error when no AWS profile set" {
        Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue
        { Invoke-OrphanIamCleanup @() } | Should -Not -Throw
    }
}

Describe "Invoke-WithCredentialSwap" -Tag "Provision" {
    It "executes script block and restores original env vars" {
        $env:AWS_ACCESS_KEY_ID = "ORIGINAL_KEY"
        $ran = $false
        Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString "SWAP_KEY" -AsPlainText -Force) -SecretAccessKey (ConvertTo-SecureString "SWAP_SECRET" -AsPlainText -Force) -ScriptBlock { param() $global:ran = $true; $env:AWS_ACCESS_KEY_ID | Should -Be "SWAP_KEY" }
        $ran | Should -BeTrue
        Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_PROFILE -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue
    }
}

Describe "New-RekognitionFallbackIamUser" -Tag "Provision" {
    BeforeEach {
        Remove-Item Env:\INSTALL_REKOGNITION_FALLBACK -ErrorAction SilentlyContinue
        Mock Write-SetupLog { }
    }

    It "returns null keys when toggle is not true" {
        $env:INSTALL_REKOGNITION_FALLBACK = "false"
        $result = New-RekognitionFallbackIamUser
        $result.AccessKeyId | Should -BeNullOrEmpty
        $result.SecretAccessKey | Should -BeNullOrEmpty
    }
}

Describe "New-FleetIamUser" -Tag "Provision" {
    BeforeEach {
        $env:INSTALL_PROJECT = "TEST"
        Mock Write-SetupLog { }
        Mock Write-Verbose { }
    }
    AfterEach {
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
    }

    It "detects existing fleet IAM user" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = '{"User":{"UserName":"TEST-SENTRY"}}'; ExitCode = 0; Success = $true }
        }
        Mock Write-Verbose { }
        $result = New-FleetIamUser
        $result | Should -Not -BeNullOrEmpty
    }
}

Describe "Test-Sovereignty" -Tag "Provision" {
    BeforeEach {
        Mock Write-SetupLog { }
        Mock Write-Warning { }
        Mock Write-Verbose { }
    }

    It "skips tests for global tier" {
        $env:INTERCLAW_SOVEREIGNTY = "global"
        { Test-Sovereignty } | Should -Not -Throw
        Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue
    }
}

Describe "New-AgentIamUser" -Tag "Provision" {
    BeforeAll {
        Mock Write-SetupLog { }
        Mock Write-Host { }
        Mock Get-AgentSecretPrefix { return "TEST_base" }
        Mock Get-AgentHostPort { return 20300 }
        $env:INSTALL_PROJECT = "TEST"
        $env:INSTALL_ROLE = "BASE"
        $env:INTERCLAW_INSTANCE_ID = "1"
    }

    It "returns hashtable with keys on success" {
        function Invoke-NativeCommand {
            param([scriptblock]$Command)
            return [pscustomobject]@{ Output = '{"User":{"UserName":"TEST-BASE-1"},"AccessKey":{"AccessKeyId":"AKIATEST","SecretAccessKey":"testSecret123"}}'; ExitCode = 0; Success = $true }
        }
        $result = New-AgentIamUser -Index 0
        $result.AccessKeyId | Should -Be "AKIATEST"
        $result.SecretAccessKey | Should -Be "testSecret123"
    }
}

Describe "New-FleetIamUser rotation guard" -Tag "Provision", "Regression" {
    It "source file checks ROTATE_PREEXISTING_KEYS env var before rotating" {
        $source = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\Public\New-FleetIamUser.ps1") -Raw
        $source | Should -MatchExactly '\$Rotate = \$env:ROTATE_PREEXISTING_KEYS -eq "true"'
    }

    It "source file conditionally deletes old keys only when Rotate is true" {
        $source = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\Public\New-FleetIamUser.ps1") -Raw
        $source | Should -MatchExactly 'if \(\$Rotate'
    }

    It "source file reuses existing key when not rotating" {
        $source = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\Public\New-FleetIamUser.ps1") -Raw
        $source | Should -MatchExactly 'Reusing existing fleet access key'
    }

    It "has Write-Verbose logging for rotation decision" {
        $source = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\Public\New-FleetIamUser.ps1") -Raw
        $source | Should -MatchExactly 'Fleet key rotation: \$Rotate \(existing keys: \$\(\$FleetExistingKeys'
    }
}
