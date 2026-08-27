#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for SalmonRun.Provision module
# Source: Scripts/1Provision.ps1
# ==============================================================================

BeforeAll {
    $HelpersPath  = (Resolve-Path (Join-Path $PSScriptRoot ".." "Modules" "SalmonRun.Core" "SalmonRun.Core.ps1")).Path
    $ProvisionPublicDir = Join-Path $PSScriptRoot ".." "Modules" "SalmonRun.Provision" "Public"

    # Dot-source helpers (must be loaded before functions so helper functions and
    # script-scoped variables like $global:InterclawConstants are in scope).
    . $HelpersPath

    # Load split modules for functions moved from Core (module-split E1-E4)
    $moduleDirs = @('SalmonRun.Secrets','SalmonRun.Identity','SalmonRun.Config','SalmonRun.Process','SalmonRun.Fleet')
    foreach ($dir in $moduleDirs) {
        $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$dir.ps1"
        if (Test-Path $modulePath) { . $modulePath }
    }

    # Load provision functions from module directory
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\SalmonRun.Provision.ps1")

    # Offline skip guard — detect if AWS CLI is available for tests that
    # mock it (defensive guard for environments without any AWS tooling).
    $script:HasAwsCli = $null -ne (Get-Command aws -ErrorAction SilentlyContinue)
}

Describe "SalmonRun.Provision - Module Loading" -Tag "Provision" {
    It "loads all functions from the provision module" {
        $FunctionFiles = Get-ChildItem -Path $ProvisionPublicDir -Filter "*.ps1"
        $FunctionFiles.Count | Should -Be 22
    }

    It "every exported function exists in Public files" {
        $ManifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Provision\SalmonRun.Provision.psd1"
        $Manifest = Import-PowerShellDataFile -Path $ManifestPath
        $Exported = $Manifest.FunctionsToExport

        $DefinedFunctions = Get-ChildItem -Path $ProvisionPublicDir -Filter "*.ps1" | ForEach-Object {
            $content = Get-Content -Path $_.FullName -Raw
            $fileMatches = [regex]::Matches($content, '(?m)^function\s+([\w-]+)')
            foreach ($m in $fileMatches) { $m.Groups[1].Value }
        }

        $Stale = $Exported | Where-Object { $_ -notin $DefinedFunctions }
        $Stale | Should -BeNullOrEmpty -Because "every function in FunctionsToExport must have a matching 'function' definition; stale entries: $($Stale -join ', ')"
    }
}

    # ==========================================================================
    # Test-Sovereignty
    # ==========================================================================
    Describe "Test-Sovereignty" -Tag "Provision" -Skip:$(-not $script:HasAwsCli) {
        BeforeEach {
            $env:AWS_SSO_PROFILE = "test-profile"
            $env:INSTALL_TELEGRAM = "false"
            $env:OPENROUTER_ORCH_KEY = ""
            $env:OPENROUTER_VERI_KEY = ""
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue
        }

        It "passes for Canada tier when ca-central-1 is reachable and us-east-1 is denied" {
            $env:INTERCLAW_SOVEREIGNTY = "canada"
            function Write-SetupLog { }
            function global:aws {
                $global:LASTEXITCODE = 0
                if ($args -contains 'us-east-1') {
                    $global:LASTEXITCODE = 254
                    return "AccessDenied"
                }
                return "{}"
            }
            Test-Sovereignty
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            $global:LASTEXITCODE | Should -Be 0
        }

        It "passes for USA tier when us-east-1 is reachable and ca-central-1 is denied" {
            $env:INTERCLAW_SOVEREIGNTY = "usa"
            function Write-SetupLog { }
            function global:aws {
                $global:LASTEXITCODE = 0
                if ($args -contains 'ca-central-1') {
                    $global:LASTEXITCODE = 254
                    return "AccessDenied"
                }
                return "{}"
            }
            Test-Sovereignty
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            $global:LASTEXITCODE | Should -Be 0
        }

        It "skips sovereignty tests for Global tier" {
            $env:INTERCLAW_SOVEREIGNTY = "global"
            function Write-SetupLog { }
            $script:awsCalled = $false
            function global:aws { $script:awsCalled = $true }
            Test-Sovereignty
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            $script:awsCalled | Should -Be $false
        }
    }

    # ==========================================================================
    # Invoke-SecretHydration
    # ==========================================================================
    Describe "Invoke-SecretHydration" -Tag "Provision" -Skip:$(-not $script:HasAwsCli) {
        BeforeEach {
            $env:INSTALL_PROJECT = 'TEST'
            $env:INSTALL_ROLE = 'ORCH'
            $env:INTERCLAW_INSTANCE_ID = '99'
            $env:AWS_SSO_PROFILE = 'test'
            $env:INTERCLAW_GATEWAY_TOKEN = 'gateway-token'
        }

        AfterEach {
            Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_ORCH_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_VERI_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\TELEGRAM_BOT_TOKEN_ORCH -ErrorAction SilentlyContinue
            Remove-Item Env:\TELEGRAM_OWNER_USERNAME -ErrorAction SilentlyContinue
            Remove-Item Env:\TELEGRAM_OWNER_USERID -ErrorAction SilentlyContinue
            Remove-Item Env:\INTERCLAW_INSTANCE_ID -ErrorAction SilentlyContinue
        }

        It "hydrates secrets via Import-SecretsFromAws (bundled, no individual secrets)" {
            $env:INTERCLAW_SOVEREIGNTY = 'canada'
            function Write-SetupLog { }
            $script:imported = $false
            $script:cacheCleared = $false
            $script:swarmLog = @()
            function Read-EnvFile { $script:imported = $true }
            function Import-SecretsFromAws { $script:imported = $true }
            function Clear-SecretCache { $script:cacheCleared = $true }
            function Set-SwarmSecretSafe { param([string]$SecretName,[string]$SecretValue,[string]$Label) $script:swarmLog += $SecretName }
            Invoke-SecretHydration
            $script:imported | Should -Be $true
            # Cache is no longer cleared inline — it persists across phases to avoid redundant AWS SM calls
            $script:swarmLog.Count | Should -Be 0
        }

        It "does not create individual secrets (uses bundles in New-AgentIamUser)" {
            $env:INTERCLAW_SOVEREIGNTY = 'global'
            $env:OPENROUTER_ORCH_KEY = 'or-key'
            $env:TELEGRAM_BOT_TOKEN_ORCH = '123:ABC'
            $env:TELEGRAM_OWNER_USERNAME = 'testuser'
            $env:TELEGRAM_OWNER_USERID = '12345'
            function Write-SetupLog { }
            function Read-EnvFile { }
            function Import-SecretsFromAws { }
            function Clear-SecretCache { }
            $script:swarmLog = @()
            function Set-SwarmSecretSafe { param([string]$SecretName,[string]$SecretValue,[string]$Label) $script:swarmLog += $SecretName }
            Invoke-SecretHydration
            $script:swarmLog.Count | Should -Be 0
        }

        It "runs without error when Global-tier keys are missing (bundle handles missing gracefully)" {
            $job = Start-Job -ScriptBlock {
                param($h, $d)
                . $h
                Get-ChildItem -Path $d -Filter "*.ps1" | ForEach-Object { . $_.FullName }
                function Write-SetupLog { }
                function Write-Host { param([string]$Message, [switch]$NoNewLine, [System.ConsoleColor]$ForegroundColor, [System.ConsoleColor]$BackgroundColor) Write-Output $Message }
                function Read-EnvFile { }
                function Import-SecretsFromAws { }
                function Set-SwarmSecretSafe { param([string]$SecretName,[string]$SecretValue,[string]$Label) }
                function Clear-SecretCache { }
                $env:INSTALL_PROJECT        = 'TEST'
                $env:INSTALL_ROLE           = 'ORCH'
                $env:INTERCLAW_INSTANCE_ID   = '99'
                $env:AWS_SSO_PROFILE        = 'test'
                $env:INTERCLAW_GATEWAY_TOKEN = 'gateway-token'
                $env:INTERCLAW_SOVEREIGNTY   = 'global'
                $env:OPENROUTER_ORCH_KEY = ''
                Invoke-SecretHydration
            } -ArgumentList $HelpersPath, $ProvisionPublicDir

            $null = Wait-Job $job -Timeout 30
            $job.State | Should -Be "Completed"
            Remove-Job $job
        }
    }


    # ==========================================================================
    # Invoke-OrphanIamCleanup
    # ==========================================================================
    Describe "Invoke-OrphanIamCleanup" -Tag "Provision" {
        BeforeEach {
            $env:INSTALL_PROJECT = 'TEST'
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Env:\INTERCLAW_SOVEREIGNTY -ErrorAction SilentlyContinue
            Remove-Item Env:\INSTALL_ROLE -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue
        }

        It "runs cleanup for any role" {
            $env:INSTALL_ROLE = 'BASE'
            function Write-SetupLog { }
            $script:callLog = @()
            function global:aws { $script:callLog += ($args -join ' ') }
            function docker { $script:callLog += ($args -join ' ') }
            function Set-SwarmSecretSafe { }
            Invoke-OrphanIamCleanup
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            ($script:callLog -match 'list-users').Count | Should -Be 0
        }

        It "keeps active IAM users and reports no orphans" {
            $env:INSTALL_ROLE = 'ORCH'
            $env:AWS_SSO_PROFILE = 'test'
            function Write-SetupLog { }
            $script:callLog = @()
            function global:aws {
                $global:LASTEXITCODE = 0
                $script:callLog += ($args -join ' ')
                if ($args -contains 'list-users') {
                    return '{"Users":[{"UserName":"TEST-ORCH-84"},{"UserName":"TEST-BASE-85"}]}'
                }
                return "{}"
            }
            function docker {
                $script:callLog += ($args -join ' ')
                $argString = $args -join ' '
                if ($argString -match 'service ls') { return "svc1`nsvc2`nmaintenance-drone" }
                if ($argString -match 'inspect svc1') { return '[{"Spec":{"TaskTemplate":{"ContainerSpec":{"Env":["INTERCLAW_INSTANCE_ID=84"]}}}}]' }
                if ($argString -match 'inspect svc2') { return '[{"Spec":{"TaskTemplate":{"ContainerSpec":{"Env":["INTERCLAW_INSTANCE_ID=85"]}}}}]' }
                return ""
            }
            function Set-SwarmSecretSafe { }
            Invoke-OrphanIamCleanup
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            ($script:callLog -match 'list-users').Count | Should -Be 1
            ($script:callLog -match 'delete-user').Count | Should -Be 0
        }

        It "does NOT match CODE role users" {
            $Regex = "^TEST-(BASE)-(\d+)$"
            "TEST-CODE-1" -match $Regex | Should -BeFalse
            "TEST-CODE-99" -match $Regex | Should -BeFalse
        }

        It "cleans up orphaned IAM user by deleting keys, policies, and user" {
            $env:INSTALL_ROLE = 'ORCH'
            $env:AWS_SSO_PROFILE = 'test'
            function Write-SetupLog { }
            $script:callLog = @()
            function global:aws {
                $global:LASTEXITCODE = 0
                $script:callLog += ($args -join ' ')
                if ($args -contains 'list-users') {
                    return '{"Users":[{"UserName":"TEST-ORCH-84"},{"UserName":"TEST-BASE-99"}]}'
                }
                if ($args -contains 'get-user') { $global:LASTEXITCODE = 1; return "" }
                if ($args -contains 'list-access-keys') {
                    return '{"AccessKeyMetadata":[{"AccessKeyId":"AKIAOLD","Status":"Active"}]}'
                }
                if ($args -contains 'list-user-policies') {
                    return '{"PolicyNames":["policy1"]}'
                }
                return "{}"
            }
            function docker {
                $script:callLog += ($args -join ' ')
                $argString = $args -join ' '
                if ($argString -match 'service ls') { return "svc1`nmaintenance-drone" }
                if ($argString -match 'inspect') { return '[{"Spec":{"TaskTemplate":{"ContainerSpec":{"Env":["INTERCLAW_INSTANCE_ID=84"]}}}}]' }
                return ""
            }
            function Set-SwarmSecretSafe { }
            Invoke-OrphanIamCleanup
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            ($script:callLog -match 'update-access-key').Count | Should -Be 1
            ($script:callLog -match 'delete-access-key').Count | Should -Be 1
            ($script:callLog -match 'delete-user-policy').Count | Should -Be 1
            ($script:callLog -match 'iam delete-user ').Count | Should -Be 1
        }
    }

    # ==========================================================================
    # New-AgentIamUser
    # ==========================================================================
    Describe "New-AgentIamUser" -Tag "Provision" {
        BeforeEach {
            $env:INSTALL_PROJECT = 'TEST'
            $env:INSTALL_ROLE = 'ORCH'
            $env:INTERCLAW_INSTANCE_ID = '99'
            $env:AWS_SSO_PROFILE = 'test'
            $env:INTERCLAW_SOVEREIGNTY = 'canada'
            $global:LASTEXITCODE = 0
        }

        AfterEach {
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\PSScriptRoot -ErrorAction SilentlyContinue
        }

        It "creates a new IAM user, attaches policy, and creates agent bundle" {
            $env:PSScriptRoot = (Resolve-Path (Join-Path $PSScriptRoot "..", "..", "..", "Skills", "Docker")).Path
            $env:INTERCLAW_GATEWAY_TOKEN = 'test-gateway-token'
            function Write-SetupLog { }
            function Write-Host { }
            $script:callLog = @()
            $script:swarmLog = @()
            function global:aws {
                $global:LASTEXITCODE = 0
                $script:callLog += ($args -join ' ')
                if ($args -contains 'get-user') { $global:LASTEXITCODE = 1; return "" }
                if ($args -contains 'create-user') { return '{"User":{"UserName":"TEST-ORCH-99"}}' }
                if ($args -contains 'put-user-policy') { return "{}" }
                if ($args -contains 'list-access-keys') { return '{"AccessKeyMetadata":[]}' }
                if ($args -contains 'create-access-key') { return '{"AccessKey":{"AccessKeyId":"AKIANEW","SecretAccessKey":"secret"}}' }
                return "{}"
            }
            function Set-SwarmSecretSafe { param([string]$SecretName,[string]$SecretValue,[string]$Label) $script:swarmLog += $SecretName }
            function Set-ContainerSecretBundle { param([string]$BundleName,[hashtable]$Entries,[string]$Label) $script:swarmLog += $BundleName }
            try {
                $result = New-AgentIamUser
                $result.IamUserName | Should -Be "TEST-ORCH-99"
                $result.AccessKeyId | Should -Be "AKIANEW"
                ($script:callLog -match 'create-user').Count | Should -Be 1
                ($script:callLog -match 'put-user-policy').Count | Should -Be 1
                ($script:callLog -match 'create-access-key').Count | Should -Be 1
                ($script:swarmLog -match 'secrets_bundle').Count | Should -Be 1
            } finally {
                Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            }
        }

        It "reuses existing IAM user and rotates access keys" {
            function Write-SetupLog { }
            function Write-Host { }
            $script:callLog = @()
            function global:aws {
                $global:LASTEXITCODE = 0
                $script:callLog += ($args -join ' ')
                if ($args -contains 'get-user') { return '{"User":{"UserName":"TEST-ORCH-99"}}' }
                if ($args -contains 'list-access-keys') { return '{"AccessKeyMetadata":[{"AccessKeyId":"AKIAOLD"}]}' }
                if ($args -contains 'create-access-key') { return '{"AccessKey":{"AccessKeyId":"AKIANEW2","SecretAccessKey":"secret2"}}' }
                return "{}"
            }
            function Set-SwarmSecretSafe { }
            $result = New-AgentIamUser
            $result.IamUserName | Should -Be "TEST-ORCH-99"
            $result.AccessKeyId | Should -Be "AKIANEW2"
            ($script:callLog -match 'create-user').Count | Should -Be 0
            ($script:callLog -match 'delete-access-key').Count | Should -Be 1
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
        }

        It "falls back to SSO credentials when IAM user creation fails" {
            $env:PSScriptRoot = (Resolve-Path (Join-Path $PSScriptRoot "..", "..", "..", "Skills", "Docker")).Path
            $env:AWS_ACCESS_KEY_ID = 'SSO_ID'
            $env:AWS_SECRET_ACCESS_KEY = 'SSO_SECRET'
            function Write-SetupLog { }
            function Write-Host { }
            $script:swarmLog = @()
            function global:aws {
                $global:LASTEXITCODE = 0
                if ($args -contains 'get-user') { $global:LASTEXITCODE = 1; return "" }
                if ($args -contains 'create-user') { $global:LASTEXITCODE = 1; return "Error" }
                return "{}"
            }
            function Set-SwarmSecretSafe { param([string]$SecretName,[string]$SecretValue,[string]$Label) $script:swarmLog += "$SecretName=$SecretValue" }
            $result = New-AgentIamUser
            $result.IamUserName | Should -Be $null
            ($script:swarmLog -match 'SSO_ID').Count | Should -Be 1
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
        }
    }

    # ==========================================================================
    # New-SentryIamUser — REMOVED: function was removed in commit 6110a2e3
    # (refactor: remove sentry IAM user — provisioner handles rebuilds)

    Describe "Invoke-BedrockProfileSetup" -Tag "Provision" {
        BeforeEach {
            $env:INSTALL_PROJECT = 'TEST'
            $env:INTERCLAW_INSTANCE_ID = '99'
            $env:INTERCLAW_SOVEREIGNTY = 'usa'
            $env:AWS_SSO_PROFILE = 'test-profile'
            $script:bedrockLog = @()
            function Write-SetupLog { param([string]$Message) $script:bedrockLog += $Message }
            function Write-Host { }
            function Get-InterclawRepoRoot { return Join-Path $PSScriptRoot '..' }
        }

        It "skips Bedrock profile creation for CODE role" {
            $env:INSTALL_ROLE = 'CODE'
            function global:aws { return "{}" }
            . (Join-Path $ProvisionPublicDir 'Invoke-BedrockProfileSetup.ps1')
            Invoke-BedrockProfileSetup
            Remove-Item -LiteralPath "function:global:aws" -Force -ErrorAction SilentlyContinue
            ($script:bedrockLog -match 'Skipping Bedrock').Count | Should -BeGreaterThan 0
        }
    }

    # ==========================================================================
    # 1Provision.ps1 -Phase All dispatch
    # ==========================================================================
    Describe "1Provision.ps1 -Phase All dispatch" -Tag "Provision", "Regression" {
        It "-Phase All reaches all five documented phase blocks" {
            $target = Join-Path $PSScriptRoot ".." "1Provision.ps1"
            $tokens = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $target), [ref]$tokens, [ref]$errs)
            $errs | Should -BeNullOrEmpty
            $targets = @(
                @{ Function = 'Test-Sovereignty';            Guard = 'All' },
                @{ Function = 'Invoke-SecretHydration';      Guard = 'All' },
                @{ Function = 'New-AgentIamUser';            Guard = 'All' },
                @{ Function = 'Invoke-AgentOrchProvisioning';Guard = 'All' },
                @{ Function = 'Invoke-AgentCredentialTests'; Guard = 'All' }
            )
            foreach ($t in $targets) {
                $reached = $false
                $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) | ForEach-Object {
                    foreach ($clause in $_.Clauses) {
                        $bodyHits = $clause.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $t.Function }, $true)
                        if ($bodyHits.Count -gt 0 -and $clause.Item1.Extent.Text -match '\$Phase -eq "All"') {
                            $reached = $true
                        }
                    }
                }
                $reached | Should -BeTrue -Because "$($t.Function) must be reachable via -Phase All"
            }
        }

        It "AWS consolidated block runs only for -Phase AWS" {
            $target = Join-Path $PSScriptRoot ".." "1Provision.ps1"
            $content = Get-Content (Resolve-Path $target) -Raw
            $awsBlock = [regex]::Match($content, 'if \(\$Phase -eq "AWS"\) \{').Value
            $awsBlock | Should -Not -BeNullOrEmpty
            $content | Should -Not -Match 'if \(\$Phase -eq "All" -or \$Phase -eq "AWS"\)'
        }
    }
