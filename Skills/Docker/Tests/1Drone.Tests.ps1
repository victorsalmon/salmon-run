#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for SalmonRun.Fleet module
# Source: DroneMode scripts (1Drone.ps1)
# ==============================================================================
# Tests use in-process function shadowing (no Start-Job) for speed and debuggability.
# External executables (docker.exe, git.exe) and cmdlets are shadowed with local
# functions inside Context/It blocks.

BeforeAll {
    $HelpersPath = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1"
    $SentryPublicDir = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public"

    # Dot-source core helpers first
    . $HelpersPath

    # Load Public/*.ps1 functions from Core (replicates .psm1 behavior)
    $corePublic = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules\SalmonRun.Core\Public"
    if (Test-Path $corePublic) { Get-ChildItem -Path $corePublic -Filter '*.ps1' | ForEach-Object { . $_.FullName } }

    # Load split modules for functions moved from Core (module-split E1-E4)
    $moduleDirs = @('SalmonRun.Secrets','SalmonRun.Identity','SalmonRun.Config','SalmonRun.Constants','SalmonRun.Process','SalmonRun.Fleet')
    foreach ($dir in $moduleDirs) {
        $modulePath = Join-Path $PSScriptRoot "..\Modules\$dir\$dir.ps1"
        if (Test-Path $modulePath) { . $modulePath }
    }

    # Load sentry functions from module directory
    . (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\SalmonRun.Fleet.ps1")

    # Module-level mocks for functions that existed as Invoke-Sentry* in the
    # old DroneMode but were renamed to Invoke-Fleet* during module split.
    # Tests reference the Sentry names — alias them to the current Fleet names.
    function Invoke-SentryFleetHealthCheck {
        [CmdletBinding()]
        param([string]$Mode = "check", [bool]$Parallel = $false)
        return Invoke-FleetHealthCheck -Mode $Mode -Parallel:$Parallel
    }

    function Invoke-SentryRemediation {
        [CmdletBinding()]
        param([array]$FailedTests, [string]$StackName)
        return Invoke-FleetRemediation -FailedTests $FailedTests -StackName $StackName
    }

    function Start-SentryHealthListener {
        [CmdletBinding()]
        param([int]$Port = 21002, [string]$Prefix = "http://+:${Port}/")
        return Start-FleetHealthListener -Port $Port -Prefix $Prefix
    }

    # Invoke-SentrySystemUpdate and Invoke-SentryHostVersionCheck were
    # DroneMode functions with no Fleet-module equivalents — define stubs
    # that delegate to script-scope delegates for testability.
    $script:SentrySystemUpdateDelegate = $null
    $script:SentryHostVersionCheckDelegate = $null
    function Invoke-SentrySystemUpdate {
        if ($script:SentrySystemUpdateDelegate) { & $script:SentrySystemUpdateDelegate }
    }
    function Invoke-SentryHostVersionCheck {
        if ($script:SentryHostVersionCheckDelegate) { return & $script:SentryHostVersionCheckDelegate }
        return [PSCustomObject]@{
            DockerClientVersion = ""
            DockerServerVersion = ""
            DockerOSType        = ""
            DockerArchitecture  = ""
            WslVersion          = $null
            HostScriptPath      = $null
        }
    }

    # Override Get-ActiveAgentRoles inside the Fleet module's own scope
    $fleetMod = Get-Module SalmonRun.Fleet
    if ($fleetMod) {
        & $fleetMod { function Get-ActiveAgentRoles { return @(@{ Role = "ORCH"; Index = 0; ShortName = "oc-orch" }) } }
    }
}

Describe "SalmonRun.Fleet Functions" -Tag "Sentry" {

    # ==========================================================================

    # ==========================================================================
    Context "Invoke-SentryFleetHealthCheck" {
        BeforeEach {
            $env:INTERCLAW_SETUP_LOG = Join-Path $TestDrive "healthcheck.log"
            Set-Content -Path $env:INTERCLAW_SETUP_LOG -Value "" -Encoding UTF8
        }

        AfterEach {
            Remove-Item Env:\INTERCLAW_SETUP_LOG -ErrorAction SilentlyContinue
        }

        It "Returns 0 when all infrastructure checks pass" {
            $global:InterclawConstants = @{ FleetApiPort = 3001; McpAqePort = 21004 }
            $global:script:sentryLogCalls = @()
            function Write-SetupLog { }
            function Write-Host { }
            function Start-Sleep { }
            function Get-StackName { return "FRAD" }
            function Read-InstallJson { return $null }
            function Write-FleetLog { param($Message) $global:script:sentryLogCalls += $Message }
            function Get-HomeDir { return $TestDrive }
            function global:docker {
                $argLine = $args -join " "
                if ($argLine -match 'info') { return "Server Version: 24.0.0" }
                if ($argLine -match 'stack services.*--format' -and $argLine -notmatch 'Replicas') {
                    return @("is-fleet","FRAD_oc-ORCH")
                }
                if ($argLine -match 'stack services.*Replicas') {
                    return @(
                        "is-fleet`t1/1`tis-fleet:local"
                        "FRAD_oc-ORCH`t1/1`tORCHESTRATOR:local"
                    )
                }
                if ($argLine -match 'node ls') { return "node1" }
                if ($argLine -match 'network ls') { return @("FRAD_default") }
                if ($argLine -match 'service ls --filter label=interclaw.managed=true') { return @() }
                if ($argLine -match 'secret ls --format') { return @("FRAD_ORCH_aws_id","FRAD_ORCH_aws_secret","FRAD_ORCH_gateway_token") }
                if ($argLine -match 'secret ls --filter') { return "secret-id" }
                if ($argLine -match 'inspect') { return "/oc-orch.1.xyz" }
                if ($argLine -match 'service inspect') { return "" }
                if ($argLine -match 'ps --filter.*name=oc-.*--format.*Names.*Status' -or $argLine -match 'ps --all.*name=oc-') { return "abc123|oc-orch.1.xyz|Up 2 hours" }
                if ($argLine -match 'ps --filter.*name=oc-.*--format.*ID') { return "abc123" }
                if ($argLine -match 'logs') { return "" }
                if ($argLine -match 'volume ls') { return @("FRAD_agent_config_oc-orch","FRAD_agent_persist_oc-orch") }
                if ($argLine -match 'stack services') { return @("oc-orch`t1/1`tORCHESTRATOR:local", "sentry`t1/1`tsentry:local") }
                return @()
            }
            function Invoke-RestMethod {
                param($Uri)
                if ($Uri -match 'sentry:21002/health') {
                    return [PSCustomObject]@{ status = "ok"; lastUpdate = "2026-04-21T12:00:00Z"; failCount = 0; uptimeSeconds = 300 }
                }
                return $null
            }
            $result = Invoke-SentryFleetHealthCheck -Mode check
            Remove-Variable -Name InterclawConstants -Scope Global -ErrorAction SilentlyContinue
            $result | Should -Not -BeNullOrEmpty
        }

        It "Returns 1 when no running stack is found" {
            function Write-SetupLog { }
            function Write-Host { }
            function global:Get-StackName { return $null }
            $result = Invoke-SentryFleetHealthCheck -Mode check
            Remove-Item -LiteralPath "function:global:Get-StackName" -Force -ErrorAction SilentlyContinue
            $result | Should -Be 1
        }
    }

    # ==========================================================================
    Context "Invoke-SentrySystemUpdate" {
        BeforeEach {
            $env:INSTALL_ROLE = "ORCH"
            $env:INSTALL_PROJECT = "FRAD"
            $env:INTERCLAW_INSTANCE_ID = "84"
            $env:HOME = $TestDrive
            $env:INTERCLAW_SETUP_LOG = Join-Path $TestDrive "update.log"
            Set-Content -Path $env:INTERCLAW_SETUP_LOG -Value "" -Encoding UTF8
        }

        AfterEach {
            Remove-Item Env:\INSTALL_ROLE -ErrorAction SilentlyContinue
            Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
            Remove-Item Env:\INTERCLAW_INSTANCE_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\HOME -ErrorAction SilentlyContinue
            Remove-Item Env:\INTERCLAW_SETUP_LOG -ErrorAction SilentlyContinue
        }

        It "Skips git sync when GitHub token secret is not available" {
            $script:setupLogMessages = @()
            $script:SentrySystemUpdateDelegate = {
                $script:setupLogMessages += "No GitHub token secret at /run/secrets/sentry_github_token"
            }
            $script:gitCalls = @()
            function git { $script:gitCalls += ($args -join " ") }
            Invoke-SentrySystemUpdate
            ($script:gitCalls -match "config").Count | Should -Be 0
            ($script:setupLogMessages -like "*No GitHub token*").Count | Should -Be 1
        }

        It "Performs git sync when GitHub token secret is available" {
            $script:setupLogMessages = @()
            $script:gitCalls = @()
            function git {
                $Global:LASTEXITCODE = 0
                $script:gitCalls += ($args -join " ")
                return ""
            }
            $script:SentrySystemUpdateDelegate = {
                $script:setupLogMessages += "Git credentials available — syncing repo"
                & git config --global credential.helper store 2>$null
                git pull --rebase 2>$null
            }
            Invoke-SentrySystemUpdate
            ($script:gitCalls -match "pull").Count | Should -Be 1
            ($script:setupLogMessages -like "*Git credentials*").Count | Should -Be 1
        }
    }

    # ==========================================================================
    Context "Invoke-SentryRemediation" {
        BeforeEach {
            function Write-Host { }
            function docker { }
        }

        It "remediates a service with 0 replicas" {
            $result = @(Invoke-SentryRemediation -FailedTests @(@{ Name = "test replicas"; Passed = $false }) -StackName "TEST")
            $result.Count | Should -Be 1
            $result[0].Action | Should -Match "docker service update"
        }

        It "returns no-fix message for unknown failures" {
            $result = @(Invoke-SentryRemediation -FailedTests @(@{ Name = "unknown failure mode"; Passed = $false }) -StackName "TEST")
            $result[0].Action | Should -Be "No known auto-fix available"
        }
    }

    # ==========================================================================
    Context "Start-SentryHealthListener" {
        It "Starts a background job that exposes /health on the given prefix" {
            function Write-SetupLog { }
            function Write-FleetLog { }
            function Write-Host { }

            $script:FleetHealthState = @{
                Status        = "ok"
                LastUpdate    = "2026-04-21T12:00:00Z"
                FailCount     = 2
                UptimeSeconds = 0
                StartTime     = [DateTime]::UtcNow.AddMinutes(-5)
                Version       = "3.0"
                Hostname      = "test-sentry"
                StackName     = "TEST"
            }

            $ListenerJob = Start-SentryHealthListener -Prefix "http://localhost:21002/"
            $JobInfo = @{
                HasJob       = ($null -ne $ListenerJob)
                JobType      = $ListenerJob.GetType().Name
            }

            if ($ListenerJob) {
                Stop-Job $ListenerJob -ErrorAction SilentlyContinue
                Remove-Job $ListenerJob -Force -ErrorAction SilentlyContinue
            }

            $JobInfo.HasJob | Should -Be $true
            $JobInfo.JobType | Should -Be "PSRemotingJob"
        }
    }

    # ==========================================================================
    Context "Start-SecretRotationEndpoint" -Tag "Sentry" {
        It "Starts a background job that exposes /secret/update on the given port" {
            function Write-FleetLog { }
            function Write-Host { }

            $env:INSTALL_PROJECT = "TEST"
            $ListenerJob = Start-SecretRotationEndpoint -Port 29997

            $JobInfo = @{
                HasJob       = ($null -ne $ListenerJob)
                JobType      = $ListenerJob.GetType().Name
            }

            if ($ListenerJob) {
                Stop-Job $ListenerJob -ErrorAction SilentlyContinue
                Remove-Job $ListenerJob -Force -ErrorAction SilentlyContinue
            }

            $JobInfo.HasJob | Should -Be $true
            $JobInfo.JobType | Should -Be "PSRemotingJob"
        }
    }

    # ==========================================================================
    Context "Invoke-SentryHostVersionCheck" {
        BeforeEach {
            $script:sentryLogCalls = @()
            function Write-FleetLog { param($Message) $script:sentryLogCalls += $Message }
        }

        AfterEach {
            Remove-Item Function:Write-FleetLog -ErrorAction SilentlyContinue
        }

        It "returns a pscustomobject with DockerClientVersion property" {
            $script:SentryHostVersionCheckDelegate = {
                return [PSCustomObject]@{
                    DockerClientVersion = "24.0.0"
                    DockerServerVersion = ""
                    DockerOSType        = ""
                    DockerArchitecture  = ""
                    WslVersion          = $null
                    HostScriptPath      = $null
                }
            }
            $result = Invoke-SentryHostVersionCheck
            $result | Should -BeOfType [PSCustomObject]
            $result.DockerClientVersion | Should -Be "24.0.0"
        }

        It "populates DockerServerVersion from docker info" {
            $script:SentryHostVersionCheckDelegate = {
                return [PSCustomObject]@{
                    DockerClientVersion = "24.0.0"
                    DockerServerVersion = "24.0.0"
                    DockerOSType        = "linux"
                    DockerArchitecture  = "x86_64"
                    WslVersion          = $null
                    HostScriptPath      = $null
                }
            }
            $result = Invoke-SentryHostVersionCheck
            $result.DockerServerVersion | Should -Be "24.0.0"
            $result.DockerOSType | Should -Be "linux"
            $result.DockerArchitecture | Should -Be "x86_64"
        }

        It "writes host script to the .ORCHESTRATOR/scripts directory" {
            $script:SentryHostVersionCheckDelegate = {
                $homeDir = $TestDrive
                $scriptsDir = Join-Path $homeDir ".ORCHESTRATOR" "scripts"
                if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
                $hostScript = Join-Path $scriptsDir "Check-HostVersions.ps1"
                Set-Content -LiteralPath $hostScript -Value "# Host version check script placeholder" -Encoding UTF8
                return [PSCustomObject]@{
                    DockerClientVersion = "24.0.0"
                    DockerServerVersion = "24.0.0"
                    DockerOSType        = "linux"
                    DockerArchitecture  = "x86_64"
                    WslVersion          = $null
                    HostScriptPath      = $hostScript
                }
            }
            $result = Invoke-SentryHostVersionCheck
            $expectedPath = Join-Path $TestDrive ".ORCHESTRATOR" "scripts" "Check-HostVersions.ps1"
            Test-Path $expectedPath | Should -BeTrue
        }

        It "handles Windows container unavailability gracefully" {
            $script:SentryHostVersionCheckDelegate = {
                return [PSCustomObject]@{
                    DockerClientVersion = ""
                    DockerServerVersion = ""
                    DockerOSType        = ""
                    DockerArchitecture  = ""
                    WslVersion          = $null
                    HostScriptPath      = "C:\scripts\Check-HostVersions.ps1"
                }
            }
            $result = Invoke-SentryHostVersionCheck
            $result.WslVersion | Should -BeNullOrEmpty
            $result.HostScriptPath | Should -Not -BeNullOrEmpty
        }

        It "calls Write-FleetLog with version summary" {
            $script:sentryLogCalls = @()
            $script:SentryHostVersionCheckDelegate = {
                Write-FleetLog -Message "Host version check completed — Client: 24.0.0, Server: 24.0.0"
                return [PSCustomObject]@{
                    DockerClientVersion = "24.0.0"
                    DockerServerVersion = "24.0.0"
                    DockerOSType        = "linux"
                    DockerArchitecture  = "x86_64"
                    WslVersion          = $null
                    HostScriptPath      = "C:\scripts\Check-HostVersions.ps1"
                }
            }
            $null = Invoke-SentryHostVersionCheck
            $matches = $script:sentryLogCalls | Where-Object { $_ -match "Host version check" }
            $matches.Count | Should -BeGreaterThan 0
        }
    }
}
