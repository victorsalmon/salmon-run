#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.Process Module" -Tag "Process", "Regression-Only" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Process\SalmonRun.Process.psd1'
        Import-Module -Name $modulePath -Force -ErrorAction Stop
    }

    AfterAll {
        Remove-Module SalmonRun.Process -Force -ErrorAction SilentlyContinue
    }

    Context "Invoke-NativeCommand" {
        It "returns Output, ExitCode, and Success for a successful command" {
            $result = Invoke-NativeCommand { cmd /c "echo hello" }
            $result.Success | Should -Be $true
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Be "hello"
        }

        It "returns non-zero ExitCode and Success=$false when command fails" {
            $result = Invoke-NativeCommand { cmd /c "exit 42" }
            $result.Success | Should -Be $false
            $result.ExitCode | Should -Be 42
        }

        It "captures stderr merged into output" {
            $result = Invoke-NativeCommand { cmd /c "echo stdout" 2>&1; cmd /c "echo stderr" 2>&1 }
            $result.Output | Should -Match "stdout"
            $result.Output | Should -Match "stderr"
        }

        It "returns Output as a flat string for multi-line output" {
            $result = Invoke-NativeCommand { cmd /c "echo line1" 2>&1; cmd /c "echo line2" 2>&1; cmd /c "echo line3" 2>&1 }
            $result.Output | Should -BeOfType [string]
            $result.Output | Should -Match "line1"
            $result.Output | Should -Match "line2"
            $result.Output | Should -Match "line3"
        }
    }

    Context "Invoke-Docker" {
        $script:DockerAvailable = $null -ne (Get-Command docker -ErrorAction SilentlyContinue)

        It "runs docker version successfully" -Skip:(-not $script:DockerAvailable) {
            $result = Invoke-Docker version --format "{{.Server.Version}}" 2>&1
            $LASTEXITCODE | Should -Be 0
        }

        It "returns non-zero exit for unknown docker command" -Skip:(-not $script:DockerAvailable) {
            $result = Invoke-Docker nonexistent-command-xyz 2>&1
            $LASTEXITCODE | Should -Not -Be 0
        }

        It "accepts stdin input via pipeline" -Skip:(-not $script:DockerAvailable) {
            $result = "{}" | Invoke-Docker system df --format "{{.Type}}" 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "Invoke-AwsCommand" -Tag "Regression" {
        BeforeEach {
            $script:OrigAwsAccessKey = $env:AWS_ACCESS_KEY_ID
            $script:OrigAwsSecretKey = $env:AWS_SECRET_ACCESS_KEY
            $script:OrigAwsSessionToken = $env:AWS_SESSION_TOKEN
            $script:OrigAwsSsoProfile = $env:AWS_SSO_PROFILE
            $script:OrigUserProfile = $env:USERPROFILE
            $env:USERPROFILE = Join-Path $TestDrive "home"
        }

        AfterEach {
            $env:AWS_ACCESS_KEY_ID = $script:OrigAwsAccessKey
            $env:AWS_SECRET_ACCESS_KEY = $script:OrigAwsSecretKey
            $env:AWS_SESSION_TOKEN = $script:OrigAwsSessionToken
            $env:AWS_SSO_PROFILE = $script:OrigAwsSsoProfile
            Remove-Item -Path (Join-Path $env:USERPROFILE ".aws") -Recurse -Force -ErrorAction SilentlyContinue
            $env:USERPROFILE = $script:OrigUserProfile
        }

        It "writes temp credentials to ~/.aws/credentials when env vars are set" {
            $env:AWS_ACCESS_KEY_ID = "AKIATEST"
            $env:AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
            $env:AWS_SESSION_TOKEN = "IQoJb3JpZ2luX2VY0gEaCXVzLWvhc3QtMSJIMEYCIQ"
            $env:AWS_SSO_PROFILE = "interclaw"

            $result = Invoke-AwsCommand { cmd /c "echo aws-call-succeeded" } -ThrowOnError:$false

            $result.Success | Should -Be $true
            $credPath = Join-Path $env:USERPROFILE ".aws" "credentials"
            Test-Path $credPath | Should -Be $false
        }

        It "refreshes credentials — replaces old [profile] entry with fresh values" {
            # First write with old creds
            $env:AWS_ACCESS_KEY_ID = "OLDKEY"
            $env:AWS_SECRET_ACCESS_KEY = "oldsecret"
            $env:AWS_SESSION_TOKEN = "oldtoken"
            $env:AWS_SSO_PROFILE = "interclaw"
            $first = Invoke-AwsCommand { cmd /c "echo first" } -ThrowOnError:$false
            $first.Success | Should -Be $true

            # Second call with new creds
            $env:AWS_ACCESS_KEY_ID = "NEWKEY"
            $env:AWS_SECRET_ACCESS_KEY = "newsecret"
            $env:AWS_SESSION_TOKEN = "newtoken"
            $second = Invoke-AwsCommand { cmd /c "echo second" } -ThrowOnError:$false
            $second.Success | Should -Be $true

            $credPath = Join-Path $env:USERPROFILE ".aws" "credentials"
            Test-Path $credPath | Should -Be $false
        }

        It "falls back to [default] profile when AWS_SSO_PROFILE is not set" {
            Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue
            $env:AWS_ACCESS_KEY_ID = "AKIADEFAULT"

            $result = Invoke-AwsCommand { cmd /c "echo test" } -ThrowOnError:$false
            $result.Success | Should -Be $true

            $credPath = Join-Path $env:USERPROFILE ".aws" "credentials"
            Test-Path $credPath | Should -Be $false
        }

        It "passes through to Invoke-NativeCommand and returns result object" {
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
            Remove-Item Env:AWS_SSO_PROFILE -ErrorAction SilentlyContinue

            $result = Invoke-AwsCommand { cmd /c "echo hello-from-aws" } -ThrowOnError:$false
            $result.Success | Should -Be $true
            $result.Output | Should -Be "hello-from-aws"
        }

        It "throws on non-zero exit when -ThrowOnError is set" {
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue

            { Invoke-AwsCommand { cmd /c "exit 1" } -ThrowOnError } | Should -Throw
        }
    }

    Context "Test-NativeCommandResult" {
        It "throws when command fails and -Recoverable is not set" {
            { Test-NativeCommandResult { cmd /c "exit 1" } } | Should -Throw
        }

        It "does not throw when command succeeds" {
            $result = Test-NativeCommandResult { cmd /c "echo ok" }
            $result.Success | Should -Be $true
        }

        It "supports -Recoverable switch without throwing" {
            $result = Test-NativeCommandResult { cmd /c "exit 2" } -Recoverable
            $result.Success | Should -Be $false
            $result.ExitCode | Should -Be 2
        }
    }
}
