<#
.SYNOPSIS
    Master orchestrator for Interclaw fleet provisioning. Runs identity wizard, per-agent setup, CODE configuration, and delegates to deployment scripts.
.DESCRIPTION
    Orchestrates all 14 deployment phases in dependency order: Host Readiness, Prerequisites,
    Identity, Fleet Toggles, AWS SSO, Tailscale, BitLocker, Docker/Swarm, Resource Preflight,
    AWS Pre-flight, IAM + Bedrock, Orchestrator Infra, Credential Isolation, Docker Secrets,
    Fleet Deploy, Config Persist, IdentityConfig, and Cleanup. Delegates to modules under
    Skills/Docker/Modules/.
.PARAMETER AutoReboot
    Automatically reboot during provisioning if required (e.g., after BitLocker or WSL2 feature enable).
.PARAMETER DroneMode
    Enable unattended provisioning with defaults from install.json. Suppresses interactive prompts.
.PARAMETER RotatePreexistingKeys
    Rotate any pre-existing AWS access keys found during credential isolation.
.PARAMETER Phase
    Run a specific phase name only. Use "All" (default) to run all phases.
    Supported: HostReadiness, Prerequisites, Identity, FleetToggles, AwsSso, Tailscale, BitLocker,
    Docker, ResourcePreflight, AwsPreflight, IamAndBedrock, OrchestratorInfrastructure,
    CredentialIsolationTests, DockerSecrets, FleetDeploy, ConfigSave, IdentityConfig, Cleanup.
.PARAMETER SkipAWSLogin
    Skip the AWS SSO login step. Useful for re-runs where SSO credentials are still valid.
    Note: Downstream phases (IamAndBedrock, CredentialIsolationTests, DockerSecrets) require a valid SSO profile.
    If AWS_SSO_PROFILE env var is also unset, the pipeline will throw a clear error.
.PARAMETER TagOnly
    Only tag phases as complete without executing them. Used for checkpoint repair.
.PARAMETER WhatIf
    Show what would be done without making any changes.
.PARAMETER PreserveFleet
    Skip fleet stack removal during cleanup, preserving the running fleet.
.PARAMETER ForceRebuild
    Delete existing local Docker images before rebuilding. Ensures clean rebuild
    when images are corrupted or stale. Without this flag, source-hash staleness
    detection determines rebuilds.
.PARAMETER OnlyVerify
    Skip all build, secret, and deploy phases. Only run fleet deployment health
    verification and report. Provides a fast "is it healthy?" check without the
    30-minute image build overhead.
.PARAMETER ConfigOverride
    JSON string that overrides install.json values. Deep-merged at startup so all
    subsequent phases see the merged config. Allows agents to produce a partial
    config JSON (e.g. {"features":{"fleet":{"install":false}}}) without modifying
    install.json on disk.
.PARAMETER DeployRetries
    Number of times to retry FleetDeploy phase on health verification failure
    (default: 3). Each retry applies auto-remediation for known failure patterns
    (stale healthchecks, slow startup, secrets crash) before redeploying.
.EXAMPLE
    .\deploy.ps1
    Run the full deployment pipeline interactively.
.EXAMPLE
    .\deploy.ps1 -Phase Docker -WhatIf
    Preview the Docker phase without making changes.
.EXAMPLE
    .\deploy.ps1 -DroneMode -SkipAWSLogin
    Run unattended provisioning using cached install.json, skipping SSO login.
.EXAMPLE
    .\deploy.ps1 -OnlyVerify
    Quick health check — verify all fleet services are running and healthy.
.NOTES
    File: deploy.ps1
    Requires: PowerShell 7.0+, AWS CLI, Docker Desktop
    See-also: config.ps1, 1Install.ps1, 1Provision.ps1, 1Deploy.ps1
#
# Credential scope by phase (R=Read, W=Write, RW=ReadWrite):
# Phase                     | Scope
# --------------------------|------------------------------------------
# HostReadiness             | No credentials
# Prerequisites             | No credentials
# Identity                  | No credentials
# FleetToggles              | No credentials
# AwsSso                    | ReadWrite AWS SM (SSO tokens)
# Tailscale                 | Host OS
# BitLocker                 | Host OS
# Docker                    | Docker API
# ResourcePreflight         | No credentials
# AwsPreflight              | ReadWrite AWS SM
# IamAndBedrock             | Write IAM, Read AWS SM
# OrchestratorInfrastructure| ReadWrite AWS SM, Write IAM
# CredentialIsolationTests  | ReadWrite AWS SM
# DockerSecrets             | Read AWS SM, Write Docker Swarm
# FleetDeploy               | Docker API, ReadWrite AWS SM
# ConfigSave                | No credentials
# IdentityConfig            | No credentials
# Cleanup                   | No credentials
#>
# ==============================================================================
# ORCHESTRATOR MASTER ORCHESTRATOR (v19.0 - thin pipeline, delegates to modules)
# ==============================================================================
param (
    [switch]$AutoReboot,
    [switch]$DroneMode,
    [switch]$RotatePreexistingKeys,
    [ValidateSet("", "All", "HostReadiness", "Prerequisites", "Identity", "FleetToggles", "ExportInstallJson", "AwsSso", "Tailscale", "BitLocker", "Docker", "ResourcePreflight", "AwsPreflight", "IamAndBedrock", "OrchestratorInfrastructure", "CredentialIsolationTests", "DockerSecrets", "FleetPreflight", "FleetDeploy", "ConfigSave", "IdentityConfig", "Cleanup")]
    [string]$Phase = "",
    [switch]$SkipAWSLogin,
    [switch]$TagOnly,
    [switch]$WhatIf,
    [switch]$PreserveFleet,
    [switch]$ForceRebuild,
    [switch]$OnlyVerify,
    [ValidateNotNull()]
    [string]$ConfigOverride = "",
    [ValidateNotNull()]
    [ValidateRange(1, 10)]
    [int]$DeployRetries = 3
)

$ErrorActionPreference = "Stop"
Set-Variable -Name PSNativeCommandArgumentPassing -Value 'Legacy' -Scope Script
$InformationPreference = "Continue"

if (-not $env:INTERCLAW_RUN_ID) { $env:INTERCLAW_RUN_ID = [Guid]::NewGuid().ToString("N").Substring(0, 8) }
if (-not $env:INTERCLAW_LOG_LEVEL) { $env:INTERCLAW_LOG_LEVEL = "INFO" }
$ScriptName = Split-Path -Leaf $PSCommandPath
Write-Information -MessageData "--- ORCHESTRATOR SETUP START (log level: $env:INTERCLAW_LOG_LEVEL) ---" -Tags "INFO"

if ($DroneMode -and $TagOnly) {
    throw "Parameters -DroneMode and -TagOnly are mutually exclusive. DroneMode executes the pipeline; TagOnly tags phases without executing."
}

if ($Phase -eq "All") { $Phase = "" }
$script:SelectedPhase = $Phase
$script:TagOnly = $TagOnly
$checkpointFile = Join-Path $PSScriptRoot ".deploy-checkpoint.json"
$script:CompletedPhases = @()
if ([string]::IsNullOrEmpty($Phase) -and (Test-Path $checkpointFile)) {
    try {
        $cp = Get-Content $checkpointFile -Raw | ConvertFrom-Json
        if ($null -ne $cp -and $cp.completed_phases) {
            $script:CompletedPhases = @($cp.completed_phases)
            if ($cp.run_id -ne $env:INTERCLAW_RUN_ID) {
                Write-Host "Deploy checkpoint found from run $($cp.run_id) — last completed phase: $($cp.last_phase)" -ForegroundColor Yellow
                Write-Host "Rerun with -Phase <name> to resume, or delete $checkpointFile to start fresh." -ForegroundColor Yellow
            }
        }
    } catch {
        Write-SetupLog "Could not read deploy checkpoint: $_" -Level WARN
    }
}

# 1. Path Initialization
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$HomeDir = (Get-Item ~).FullName
$InterclawConfigDir = Join-Path $HomeDir ".ORCHESTRATOR"
$InstallJsonPath = Join-Path $RepoRoot "install.json"

$__modulesDir = Join-Path $RepoRoot "Skills" "Docker" "Modules"
$__salmonModulesDir = Join-Path $RepoRoot "Skills" "Orchestrator" "Salmon" "Modules"
$env:PSModulePath = "$__modulesDir;$__salmonModulesDir;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $RepoRoot
Import-InterclawModule Diagnostics

$PhaseDependencies = @{
    'HostReadiness'            = @()
    'Prerequisites'            = @('HostReadiness')
    'Identity'                 = @('Prerequisites')
    'FleetToggles'             = @('Identity')
    'AwsSso'                   = @('Identity')
    'Tailscale'                = @()
    'BitLocker'                = @()
    'Docker'                   = @('HostReadiness')
    'ResourcePreflight'        = @('Docker')
    'AwsPreflight'             = @('AwsSso')
    'IamAndBedrock'            = @('AwsSso')
    'OrchestratorInfrastructure' = @('Docker')
    'CredentialIsolationTests' = @('Identity')
    'DockerSecrets'            = @('AwsSso', 'Identity')
    'FleetPreflight'           = @('Docker', 'DockerSecrets')
    'FleetDeploy'              = @('Docker', 'DockerSecrets', 'FleetPreflight')
    'ConfigSave'               = @()
    'IdentityConfig'           = @('ConfigSave')
    'Cleanup'                  = @()
}

if ($script:SelectedPhase -and $PhaseDependencies.ContainsKey($script:SelectedPhase)) {
    $prereqs = $PhaseDependencies[$script:SelectedPhase]
    if ($prereqs.Count -gt 0) {
        $cp = $null
        if (Test-Path $checkpointFile) { try { $cp = Get-Content $checkpointFile -Raw | ConvertFrom-Json } catch { Write-Debug "deploy.ps1: failed to read checkpoint from '$checkpointFile': $_" } }
        $completedSet = if ($null -ne $cp -and $cp.completed_phases) { @($cp.completed_phases) } else { @() }
        $missing = $prereqs | Where-Object { $_ -notin $completedSet }
        if ($missing.Count -gt 0) {
            throw "Phase '$($script:SelectedPhase)' requires prerequisites: $($prereqs -join ', ') — missing: $($missing -join ', '). Run full deploy or complete prerequisite phases first. Use -Phase All to run all phases."
        }
        Write-SetupLog "Phase dependency check: all $($prereqs.Count) prerequisite(s) for '$($script:SelectedPhase)' satisfied"
    }
} elseif ([string]::IsNullOrEmpty($Phase) -and $PhaseDependencies.Count -gt 0) {
    $phaseOrder = @('HostReadiness','Prerequisites','Identity','FleetToggles','ExportInstallJson','AwsSso','Tailscale','BitLocker','Docker','ResourcePreflight','AwsPreflight','IamAndBedrock','OrchestratorInfrastructure','CredentialIsolationTests','DockerSecrets','FleetPreflight','FleetDeploy','ConfigSave','IdentityConfig','Cleanup')
    $cp = $null
    if (Test-Path $checkpointFile) { try { $cp = Get-Content $checkpointFile -Raw | ConvertFrom-Json } catch { Write-Debug "deploy.ps1: failed to read checkpoint from '$checkpointFile': $_" } }
    $completedSet = if ($null -ne $cp -and $cp.completed_phases) { @($cp.completed_phases) } else { @() }
    if ($completedSet.Count -gt 0) {
        $orderedCompleted = $phaseOrder | Where-Object { $_ -in $completedSet }
        $orderedCompleted | ForEach-Object -Begin { $lastIdx = -1 } -Process {
            $idx = [array]::IndexOf($phaseOrder, $_)
            if ($idx -lt $lastIdx) {
                Write-SetupLog "Phase order validation WARN: '$_' completed at index $idx but prior phase completed at index $lastIdx" -Level WARN
            }
            $lastIdx = $idx
        }
    }
}

try {
    if ($RotatePreexistingKeys) { $env:ROTATE_PREEXISTING_KEYS = "true" }

    # Pre-set INSTALL_PROJECT before module imports (Secrets module needs it)
    if (-not $env:INSTALL_PROJECT -and (Test-Path $InstallJsonPath)) {
        $__ij = Get-Content $InstallJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $__ij -and $__ij.project -and $__ij.project.code) { $env:INSTALL_PROJECT = $__ij.project.code }
    }

    Import-InterclawModule Config; Import-InterclawModule Secrets; Import-InterclawModule Identity
    Import-InterclawModule Provision; Import-InterclawModule DeployState; Import-InterclawModule Deploy; Import-InterclawModule Fleet

    # ConfigOverride — deep-merge onto install.json so all downstream code sees the merged config
    if ($ConfigOverride) {
        try {
            $overrideObj = $ConfigOverride | ConvertFrom-Json -ErrorAction Stop
            $baseObj = Read-InstallJson -Path $InstallJsonPath
            # Deep-merge override onto base
            function Merge-InstallJsonDeep($Base, $Override) {
                if ($null -eq $Override) { return $Base }
                if ($Override -isnot [PSCustomObject] -or $Base -isnot [PSCustomObject]) { return $Override }
                $result = $Base.PSObject.Copy()
                foreach ($prop in $Override.PSObject.Properties) {
                    if ($null -eq $result.$($prop.Name)) {
                        $result | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
                    } elseif ($prop.Value -is [PSCustomObject] -and $result.$($prop.Name) -is [PSCustomObject]) {
                        $result.$($prop.Name) = Merge-InstallJsonDeep $result.$($prop.Name) $prop.Value
                    } else {
                        $result.$($prop.Name) = $prop.Value
                    }
                }
                return $result
            }
            $merged = Merge-InstallJsonDeep $baseObj $overrideObj
            # Write merged to temp file and point env var at it so Read-InstallJson picks it up
            $mergedDir = Join-Path $RepoRoot "Tasks" "Logs"
            $mergedPath = Join-Path $mergedDir "install-merged-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
            $merged | ConvertTo-Json -Depth 10 | Set-Content -Path $mergedPath -Encoding UTF8
            $env:ORCHESTRATOR_INSTALL_JSON = $mergedPath
            Write-SetupLog "ConfigOverride applied: $(($overrideObj.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')" -Level INFO
        } catch {
            Write-SetupLog "ConfigOverride processing failed: $_" -Level ERROR
            throw "ConfigOverride processing failed: $_"
        }
    }

    # OnlyVerify — quick health check, skip all phases
    if ($OnlyVerify) {
        Write-SetupLog "OnlyVerify mode: running fleet health verification only"
        $stackName = $env:INSTALL_PROJECT
        if (-not $stackName) { $stackName = (Get-InterclawConstants).DefaultProjectCode }
        try { Test-FleetDeployment -StackName $stackName; Write-Information -MessageData "  [OK] All services healthy." -Tags "INFO" }
        catch { Write-Information -MessageData "  [WARN] Health check: $($_.Exception.Message)" -Tags "WARN" }
        return
    }

    if ($ForceRebuild) { $env:ORCHESTRATOR_FORCE_REBUILD = "true" }

    # 1a. Setup Logging (after module imports so Invoke-WhatIfGuard is available)
    $LogsDir = Join-Path $RepoRoot "Tasks" "Logs"
    Invoke-WhatIfGuard -Message "Create logs directory: $LogsDir" -ScriptBlock { $null = New-Item -ItemType Directory -Path $LogsDir -Force -ErrorAction Stop -ErrorVariable logsDirErr; if ($logsDirErr) { Write-SetupLog "Logs dir create reported errors: $logsDirErr" -Level WARN } } -WhatIf $WhatIf
    $SetupLogPath = Join-Path $LogsDir "setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Invoke-WhatIfGuard -Message "Create setup log: $SetupLogPath" -ScriptBlock { Set-Content -Path $SetupLogPath -Value "# Interclaw Setup Log - $(Get-Date -Format 'o')" -Encoding UTF8; Set-Item -Path "Env:\INTERCLAW_SETUP_LOG" -Value $SetupLogPath; Write-Information -MessageData "  [OK] Setup log: $SetupLogPath" -Tags "INFO" } -WhatIf $WhatIf
    $SetupWarnLogPath = Join-Path $LogsDir "setup-warnings-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Invoke-WhatIfGuard -Message "Create WARN/FAIL log: $SetupWarnLogPath" -ScriptBlock { Set-Content -Path $SetupWarnLogPath -Value "# Interclaw Setup WARN/FAIL Log - $(Get-Date -Format 'o')" -Encoding UTF8; Set-Item -Path "Env:\INTERCLAW_SETUP_WARN_LOG" -Value $SetupWarnLogPath; Write-Information -MessageData "  [OK] WARN/FAIL log: $SetupWarnLogPath" -Tags "INFO" } -WhatIf $WhatIf

    Write-SetupLog "$ScriptName started"

    if (-not $DroneMode -and [Console]::IsInputRedirected) {
        Write-SetupLog "NonInteractive PowerShell detected (stdin redirected) — enabling DroneMode"
        $DroneMode = $true
    }

    if ($DroneMode) {
        Invoke-WhatIfGuard -Message "Initialize DroneMode" -ScriptBlock {
            if (Test-Path $InstallJsonPath) {
                $env:ORCHESTRATOR_DRONE_MODE = "1"
                Write-SetupLog "DroneMode: host-context — using install.json at $InstallJsonPath"
                Export-InstallJsonToEnv -Path $InstallJsonPath -Force
            } else {
                Initialize-DroneMode -HomeDir $HomeDir -InterclawConfigDir ([ref]$InterclawConfigDir) -InstallJsonPath ([ref]$InstallJsonPath)
            }
        } -WhatIf $WhatIf
    }
    if ($PreserveFleet) { $env:INTERCLAW_PRESERVE_FLEET = "true" }

    $script:agentConfigsResult = $null; $script:ProvisionedIds = @(); $script:AgentConfigs = @()
    $SsoProfile = $null; $script:HasCodingKeys = $true; $script:GatewayToken = $null

    if ($env:INTERCLAW_RUN_ID -and (-not $script:AgentConfigs -or $script:AgentConfigs.Count -eq 0)) {
        $__tmpResumeIj = Read-InstallJson -Path $InstallJsonPath -ErrorAction SilentlyContinue -ErrorVariable tmpResumeIjErr
        if ($tmpResumeIjErr) { Write-SetupLog "Checkpoint resume read reported errors: $($tmpResumeIjErr[0].Exception.Message)" -Level WARN }
        if ($null -ne $__tmpResumeIj -and $__tmpResumeIj.fleet -and $__tmpResumeIj.fleet.agents -and $__tmpResumeIj.fleet.agents.Count -gt 0) {
            $__tmpProjectCode = $__tmpResumeIj.project.code
            if (-not $global:ProjectCode) { $global:ProjectCode = $__tmpProjectCode }
            if (-not $global:Sovereignty) {
                $__tmpSovereigntyTier = if ($__tmpResumeIj.fleet.sovereignty) { $__tmpResumeIj.fleet.sovereignty } else { "global" }
                $global:Sovereignty = [pscustomobject]@{ Tier = $__tmpSovereigntyTier; SecretsRegion = "ca-central-1" }
            }
            $script:AgentConfigs = Resolve-AgentConfigsFromInstallJson -InstallJsonPath $InstallJsonPath -ProjectCode $__tmpProjectCode
            if ($__tmpResumeIj.features) {
                $__tmpFeat = $__tmpResumeIj.features
                if (-not $global:InstallTailscale -and $__tmpFeat.tailscale) { $global:InstallTailscale = if ($__tmpFeat.tailscale.install -eq $true -or $__tmpFeat.tailscale.install -eq "true") { "true" } else { "false" } }
                if (-not $global:InstallFleet -and $__tmpFeat.fleet) { $global:InstallFleet = if ($__tmpFeat.fleet.install -eq $true -or $__tmpFeat.fleet.install -eq "true") { "true" } else { "false" } }
                if (-not $global:InstallBrowserless -and $__tmpFeat.browserless) { $global:InstallBrowserless = if ($__tmpFeat.browserless.install -eq $true -or $__tmpFeat.browserless.install -eq "true") { "true" } else { "false" } }
                if (-not $global:InstallBookkeeping -and $__tmpFeat.Bookkeeper) { $global:InstallBookkeeping = if ($__tmpFeat.Bookkeeper.install -eq $true -or $__tmpFeat.Bookkeeper.install -eq "true") { "true" } else { "false" } }
                if (-not $global:InstallRekognitionFallback -and $__tmpFeat."rekognition-fallback") { $global:InstallRekognitionFallback = if ($__tmpFeat."rekognition-fallback".install -eq $true -or $__tmpFeat."rekognition-fallback".install -eq "true") { "true" } else { "false" } }
                if (-not $global:InstallMonitoring -and $__tmpFeat.monitoring) { $global:InstallMonitoring = if ($__tmpFeat.monitoring.install -eq $true -or $__tmpFeat.monitoring.install -eq "true") { "true" } else { "false" } }
                if (-not $global:InstallHermes -and $__tmpFeat.hermes) { $global:InstallHermes = if ($__tmpFeat.hermes.install -eq $true -or $__tmpFeat.hermes.install -eq "true") { "true" } else { "false" } }
            }
            $__tmpAgentRoles = @($script:AgentConfigs | ForEach-Object { @{ Role = $_.Role; Index = $_.Index; InstanceId = $_.InstanceId } })
            $__tmpAgentNames = @($script:AgentConfigs | ForEach-Object { $_.CustomName })
            $__tmpRoleArray = @($script:AgentConfigs | ForEach-Object { $_.Role })
            $global:Identity = [pscustomobject]@{ ProjectCode = $__tmpProjectCode; AgentNumber = $script:AgentConfigs.Count; RoleArray = $__tmpRoleArray; AgentRoles = $__tmpAgentRoles; AgentNames = $__tmpAgentNames; NextGlobalId = $script:AgentConfigs.Count + 1 }
            $global:RoleNameMap = @{}; foreach ($__tmpCfg in $script:AgentConfigs) { if ($__tmpCfg.CustomName) { $global:RoleNameMap[$__tmpCfg.Role] = $__tmpCfg.CustomName } }
            if (-not $global:InstallWorkspaceRepos -and $__tmpResumeIj.workspace -and $__tmpResumeIj.workspace.repos) {
                $global:InstallWorkspaceRepos = ($__tmpResumeIj.workspace.repos -join ','); Set-Item -Path "Env:\INSTALL_WORKSPACE_REPOS" -Value $global:InstallWorkspaceRepos -ErrorAction SilentlyContinue -ErrorVariable instWsErr; if ($instWsErr) { Write-SetupLog "INSTALL_WORKSPACE_REPOS env set reported errors: $($instWsErr[0].Exception.Message)" -Level WARN }
            }
            Remove-Variable -Name __tmpAgentRoles, __tmpAgentNames, __tmpRoleArray, __tmpCfg -ErrorAction SilentlyContinue -ErrorVariable tmpRmErr
            if ($tmpRmErr) { Write-SetupLog "Temp variable cleanup reported errors: $($tmpRmErr[0].Exception.Message)" -Level WARN }
            Write-SetupLog "Checkpoint resume: restored $($script:AgentConfigs.Count) agent config(s) from install.json" -Level INFO
        } else {
            if (Test-Path $InstallJsonPath) {
                $errMsg = "install.json found at $InstallJsonPath but is corrupted or missing 'fleet.agents' — checkpoint resume cannot continue"
                Write-SetupLog "$errMsg — delete $checkpointFile and $InstallJsonPath, then restart from Phase 1" -Level ERROR
                throw "$errMsg. Recovery: delete both $checkpointFile and $InstallJsonPath, then run deploy with -Phase All to regenerate them."
            } else {
                Write-SetupLog "Checkpoint resume: install.json not found — skip restoration" -Level WARN
            }
        }
        Remove-Variable -Name __tmpResumeIj, __tmpProjectCode, __tmpFeat, __tmpSovereigntyTier -ErrorAction SilentlyContinue -ErrorVariable tmpRm2Err
        if ($tmpRm2Err) { Write-SetupLog "Temp variable cleanup (2) reported errors: $($tmpRm2Err[0].Exception.Message)" -Level WARN }
    }

    # PHASE 0 - Host Readiness
    $__tmpHostPsd1 = Join-Path $RepoRoot "Skills" "Orchestrator" "Salmon" "Modules" "SalmonRun.Host" "SalmonRun.Host.psd1"
    if (Test-Path $__tmpHostPsd1) { Import-Module -Name $__tmpHostPsd1 -Force -DisableNameChecking -Global }
    else { Add-SetupError -Phase "HostReadiness" -Message "SalmonRun.Host module not found at $__tmpHostPsd1" -Category "Prerequisite"; throw "SalmonRun.Host module not found at $__tmpHostPsd1" }
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "HostReadiness" -ScriptBlock { Test-HostReadiness } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 1 - Prerequisites
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "Prerequisites" -ScriptBlock { Import-InterclawModule Host; Test-SalmonRunPrerequisites -DroneMode:$DroneMode; if (-not $DroneMode -and $PSVersionTable.PSVersion.Major -lt 7) { Write-SetupLog -Message "Re-launch with: pwsh -File `"$PSCommandPath`"" -Level WARN } } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 7 - Docker + Swarm (background)
    $script:dockerJob = $null
    Invoke-WhatIfGuard -Message "Launch Docker background job (Desktop + Swarm init)" -ScriptBlock {
        $script:dockerJob = Start-Job -Name DockerSetup -ScriptBlock {
            param($RepoRoot, $DroneModeBool, $SetupLogPath, $RunId)
            $modulesDir = Join-Path $RepoRoot "Skills" "Docker" "Modules"; $env:PSModulePath = "$modulesDir;$env:PSModulePath"
            Import-Module -Name (Join-Path $modulesDir "SalmonRun.Paths" "SalmonRun.Paths.psd1") -Force -DisableNameChecking -Global
            Import-Module -Name (Join-Path $modulesDir "SalmonRun.ModuleLoader" "SalmonRun.ModuleLoader.psd1") -Force -DisableNameChecking -Global
            $hostPsd1 = Join-Path $salmonModulesDir "SalmonRun.Host" "SalmonRun.Host.psd1"
            if (-not (Test-Path $hostPsd1)) { throw "SalmonRun.Host module not found at $hostPsd1" }
            Import-Module -Name $hostPsd1 -Force -DisableNameChecking -Global
            Import-Module -Name (Join-Path $modulesDir "SalmonRun.Core" "SalmonRun.Core.psd1") -Force -DisableNameChecking
            Import-InterclawModule Diagnostics
            $env:INTERCLAW_SETUP_LOG = $SetupLogPath; $env:INTERCLAW_RUN_ID = $RunId
            Write-SetupLog "Docker background job started" -Level INFO
            try {
                Write-SetupLog "Docker Background: Starting Docker Desktop..." -Level INFO
                if (-not (Start-DockerDesktop -ResetWsl -DroneMode:$DroneModeBool)) { throw "Docker Desktop failed to start" }
                Write-SetupLog "Docker Background: Docker Desktop ready. Initializing Swarm..." -Level INFO
                Initialize-DockerSwarm
                Write-SetupLog "Docker Background: Swarm initialized. Cleaning up stale resources..." -Level INFO
                Invoke-DockerCleanup -DroneMode:$DroneModeBool
                Write-SetupLog "Docker Background: Cleanup complete. Gathering memory info..." -Level INFO
                $memTotal = $null
                # MemTotal probe — docker info may be slow to respond right after swarm init; retry with jittered backoff.
                for ($attempt = 1; $attempt -le 3; $attempt++) { $result = docker info --format '{{.MemTotal}}' 2>$null; if ("$result".Trim() -match '^\d+$') { $memTotal = [long]"$result".Trim(); break }; if ($attempt -lt 3) { Start-Sleep -Seconds (Get-BackoffDelay -Attempt $attempt -Schedule @(5, 10, 20) -JitterFraction 0.25) } }
                Write-SetupLog "Docker background job complete (MemTotal=$memTotal)"
                return @{ Success = $true; MemTotal = $memTotal }
            } catch { Write-SetupLog "Docker background job FAILED: $($_.Exception.Message)" -Level ERROR; return @{ Success = $false; ErrorMessage = $_.Exception.Message } }
        } -ArgumentList $RepoRoot, ([bool]$DroneMode), $SetupLogPath, $env:INTERCLAW_RUN_ID
    } -WhatIf $WhatIf
    if ($script:dockerJob) { Write-Information -MessageData "`n[Docker] Docker setup launched in background (job #$($script:dockerJob.Id))." -Tags "INFO"; Write-Information -MessageData "  Docker Desktop will start while identity and AWS SSO are configured." -Tags "INFO"; Write-SetupLog "Docker setup launched as background job #$($script:dockerJob.Id)" }

    # PHASE 2 - Identity Resolution
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "Identity" -ScriptBlock {
        Clear-StaleEnvironment; $global:Identity = Resolve-AgentIdentity; $global:ProjectCode = $Identity.ProjectCode
        $global:RoleNameMap = Resolve-AgentNames -AgentNumber $Identity.AgentNumber -RoleArray $Identity.RoleArray -AgentNames $Identity.AgentNames
        $AgentsRoot = Join-Path $RepoRoot "Skills" "ORCHESTRATOR" "Personas"; $global:Sovereignty = Resolve-SovereigntyTier -RoleArray $Identity.RoleArray -AgentsRoot $AgentsRoot
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 3 - Fleet Toggles
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "FleetToggles" -ScriptBlock {
        $fleetResult = Initialize-FleetToggles -DroneMode:$DroneMode; $global:InstallTailscale = $fleetResult.InstallTailscale; $global:InstallFleet = $fleetResult.InstallFleet
        $global:InstallRekognitionFallback = $fleetResult.InstallRekognitionFallback; $global:InstallOpencode = $fleetResult.InstallOpencode
        $global:InstallBrowserless = $fleetResult.InstallBrowserless
        $global:InstallBookkeeping = $fleetResult.InstallBookkeeping; $global:InstallMonitoring = $fleetResult.InstallMonitoring
        $global:InstallHermes = $fleetResult.InstallHermes
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 3b - Export install.json to env
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "ExportInstallJson" -ScriptBlock { Export-InstallJsonToEnv -Path $InstallJsonPath } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 4 - AWS SSO
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "AwsSso" -ScriptBlock {
        $global:InstallWorkspaceRepos = Resolve-WorkspaceRepos -InstallJsonPath $InstallJsonPath -ProjectCode $ProjectCode -SsoProfile $env:AWS_SSO_PROFILE -SecretsRegion $Sovereignty.SecretsRegion
        if ($SkipAWSLogin) { Write-SetupLog "Skipping AWS SSO (SkipAWSLogin specified)" }
        elseif (-not $DroneMode) {
            Write-SetupLog "AWS SSO configuration"
            $ssoAttempt = 0; $ssoMax = 2
            # SSO retry backoff — 5s pause between auth attempts to avoid hammering Identity Center.
            do { $ssoAttempt++; try { $script:SsoProfile = Initialize-AwsSsoSession -SsoProfile $env:AWS_SSO_PROFILE -SecretsRegion $Sovereignty.SecretsRegion; break } catch { if ($ssoAttempt -ge $ssoMax) { Write-SetupLog "AWS SSO failed after $ssoMax attempts: $_ — falling back to cached credentials" -Level WARN; break }; Write-SetupLog "AWS SSO attempt $ssoAttempt failed: $_ — retrying in 5s" -Level WARN; Start-Sleep -Seconds 5 } } while ($ssoAttempt -lt $ssoMax)
        }
        else {
            $ssoAttempt = 0; $ssoMax = 2
            do {
                $ssoAttempt++
                try {
                    $script:SsoProfile = Initialize-AwsSsoSession -SsoProfile $env:AWS_SSO_PROFILE -SecretsRegion $Sovereignty.SecretsRegion -NonInteractive -SkipCacheRepair
                    break
                } catch {
                    if ($ssoAttempt -ge $ssoMax) {
                        Write-SetupLog "AWS SSO failed after $ssoMax attempts: $_ — attempting device-code fallback via cached profile" -Level WARN
                        try {
                            Write-SetupLog "AWS SSO fallback: verifying cached credentials still valid" -Level INFO
                            $testResult = Test-AwsSessionValidity -Profile $env:AWS_SSO_PROFILE -ErrorAction SilentlyContinue -ErrorVariable ssoTestErr
                            if ($ssoTestErr) { Write-SetupLog "SSO validity probe reported errors: $($ssoTestErr[0].Exception.Message)" -Level WARN }
                            if ($testResult) {
                                Write-SetupLog "AWS SSO fallback: cached credentials valid, proceeding with profile $($env:AWS_SSO_PROFILE)" -Level INFO
                                Write-Information -MessageData "  [OK] Using cached AWS SSO credentials (device-code gate: signing key cached from prior run)." -Tags "INFO"
                                $script:SsoProfile = $env:AWS_SSO_PROFILE
                            } else {
                                Write-SetupLog "AWS SSO fallback: cached credentials expired — all auth paths exhausted" -Level ERROR
                                throw "AWS SSO login failed after $ssoMax attempts and cached credentials are also expired. Run 'aws sso login --profile $($env:AWS_SSO_PROFILE)' manually to re-authenticate, then re-run deploy with -SkipAWSLogin."
                            }
                        } catch {
                            Write-SetupLog "AWS SSO fallback: cached credential check failed: $_" -Level ERROR
                            throw "AWS SSO login failed after $ssoMax attempts and cached credential fallback also failed: $_"
                        }
                        break
                    }
                    Write-SetupLog "AWS SSO attempt $ssoAttempt failed: $_ — retrying in 5s" -Level WARN
                    # SSO retry backoff — give Identity Center a moment between auth attempts.
                    Start-Sleep -Seconds 5
                }
            } while ($ssoAttempt -lt $ssoMax)
        }
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 5 - Tailscale
    if ($InstallTailscale -eq "true") { $script:CompletedPhases = Invoke-DeployPhase -PhaseName "Tailscale" -Recoverable:$true -ScriptBlock { Initialize-Tailscale -ProjectCode $ProjectCode -SsoProfile $SsoProfile -SecretsRegion $Sovereignty.SecretsRegion } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot }

    # PHASE 6 - BitLocker
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "BitLocker" -Recoverable:$true -ScriptBlock {
        $bitlockerResult = Test-BitLockerDrive -DroneMode:$DroneMode
        if ($bitlockerResult.RebootNeeded) { Write-Information -MessageData "`n  ==============================================" -Tags "WARN"; Write-Information -MessageData "  [REBOOT REQUIRED] BitLocker Activation" -Tags "WARN"; Write-Information -MessageData "  Run $ScriptName again after reboot to complete key escrow." -Tags "INFO"; Write-Information -MessageData "  ==============================================" -Tags "WARN"; Write-SetupLog "BitLocker: reboot required for encryption to begin" }
        if ($bitlockerResult.EscrowNeeded -and -not $bitlockerResult.KeyEscrowed) { throw "BitLocker recovery key escrow failed - will retry on next run" }
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # JOIN - Wait for Docker
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "Docker" -ScriptBlock {
        if (-not $dockerJob) { Write-Information -MessageData "  [SKIP] No background Docker job (partial re-run or standalone)." -Tags "INFO"; return }
        Write-Information -MessageData "`n[Docker] Waiting for background Docker setup to complete..." -Tags "INFO"; $null = Wait-Job $dockerJob -Timeout 300
        if ($dockerJob.State -eq "Running") { Stop-Job $dockerJob -ErrorVariable stopJobErr; if ($stopJobErr) { Write-SetupLog "Docker job stop reported errors: $($stopJobErr[0].Exception.Message)" -Level WARN }; Remove-Job $dockerJob -ErrorAction SilentlyContinue -ErrorVariable rmJobErr; if ($rmJobErr) { Write-SetupLog "Docker job remove reported errors: $($rmJobErr[0].Exception.Message)" -Level WARN }; $script:dockerJob = $null; throw "Docker setup timed out after 300 seconds. Docker Desktop may be hung." }
        $dockerResult = Receive-Job $dockerJob -ErrorVariable rcvJobErr; if ($rcvJobErr) { Write-SetupLog "Docker job receive reported errors: $($rcvJobErr[0].Exception.Message)" -Level WARN }; Remove-Job $dockerJob -ErrorAction SilentlyContinue -ErrorVariable rmJob2Err; if ($rmJob2Err) { Write-SetupLog "Docker job remove (2) reported errors: $($rmJob2Err[0].Exception.Message)" -Level WARN }; $script:dockerJob = $null
        if ($null -eq $dockerResult) { Write-SetupLog "Docker background job produced no output — likely crash (OOM or PowerShell crash)" -Level ERROR; throw "Docker background job crashed with no output — check system memory and event logs for PowerShell crash" }
        if (-not $dockerResult.Success) { Write-SetupLog "Docker background job failed: $($dockerResult.ErrorMessage)" -Level ERROR; throw "Docker setup job reported failure: $($dockerResult.ErrorMessage)" }
        Write-Information -MessageData "  [OK] Docker Desktop + Swarm ready (setup completed in background)." -Tags "INFO"; Write-SetupLog "Docker setup completed in background job (MemTotal=$($dockerResult.MemTotal))"
        if ($dockerResult.MemTotal -is [long] -and $dockerResult.MemTotal -gt 0) { $env:DOCKER_INFO_MEMTOTAL_CACHE = "$($dockerResult.MemTotal)"; Write-SetupLog "Warm MemTotal cache from background: $($dockerResult.MemTotal) bytes" -Level INFO }
        Invoke-PrePullBaseImages -TargetDir $RepoRoot
        Write-Information -MessageData "`n[ImageBuild] Launching parallel image builds in background..." -Tags "INFO"
        $buildParams = @{ TargetDir = $RepoRoot }
        if ($ForceRebuild -or $env:ORCHESTRATOR_FORCE_REBUILD -eq "true") { $buildParams.ForceRebuild = $true }
        $script:BuildContext = Start-ParallelImageBuild @buildParams
        Write-Information -MessageData "  [OK] Build jobs launched - will collect results before fleet deploy." -Tags "INFO"
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    if (-not $SsoProfile) { $SsoProfile = $env:AWS_SSO_PROFILE }
    if (-not $SsoProfile -and -not $env:AWS_SSO_PROFILE) { throw "AWS SSO profile not found and cannot be auto-detected — run Phase 2 (Identity) or check install.json" }
    if (-not $Sovereignty) { throw "Sovereignty configuration is missing — install.json may be corrupted" }
    if ($SkipAWSLogin) { Write-SetupLog "Skipping AWS SSO refresh (SkipAWSLogin specified)" }
    # SSO refresh retry backoff — 5s pause between auth attempts so Identity Center rate limits are not tripped.
    else { Invoke-WhatIfGuard -Message "Refresh AWS SSO session" -ScriptBlock { Write-SetupLog "Refreshing AWS SSO session before infrastructure phases"; $refreshRegion = if ($Sovereignty) { $Sovereignty.SecretsRegion } else { $env:AWS_SECRETS_REGION ?? "ca-central-1" }; $ssoAttempt = 0; $ssoMax = 2; do { $ssoAttempt++; try { $script:SsoProfile = Initialize-AwsSsoSession -SsoProfile $SsoProfile -SecretsRegion $refreshRegion -NonInteractive; break } catch { if ($ssoAttempt -ge $ssoMax) { Write-SetupLog "AWS SSO refresh failed after $ssoMax attempts: $_ — continuing with cached profile" -Level WARN; break }; Write-SetupLog "AWS SSO refresh attempt $ssoAttempt failed: $_ — retrying in 5s" -Level WARN; Start-Sleep -Seconds 5 } } while ($ssoAttempt -lt $ssoMax) } -WhatIf $WhatIf }

    # PHASE 8 - Resource Preflight
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "ResourcePreflight" -ScriptBlock { Remove-Item -Path "Env:\DOCKER_RESOURCES_PREFLIGHT" -ErrorAction SilentlyContinue -ErrorVariable resPrefRmErr; if ($resPrefRmErr) { Write-SetupLog "Resource preflight env remove reported errors: $($resPrefRmErr[0].Exception.Message)" -Level WARN }; $null = Test-ResourceBudget -AgentCount $Identity.AgentNumber -InstallFleet $InstallFleet -InstallTailscale $InstallTailscale -InstallBrowserless $InstallBrowserless -IncludeDiskCheck -ErrorVariable resBudgetErr; if ($resBudgetErr) { Write-SetupLog "Resource budget check reported errors: $resBudgetErr" -Level WARN }; $env:DOCKER_RESOURCES_PREFLIGHT = "done" } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 8.5 - AWS Pre-flight
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "AwsPreflight" -ScriptBlock { $script:HasCodingKeys = Invoke-AwsPreflight -SsoProfile $SsoProfile -SecretsRegion $Sovereignty.SecretsRegion -ProjectCode $ProjectCode -AgentRoles $Identity.AgentRoles -InstallOpencode $InstallOpencode -InstallBookkeeping $InstallBookkeeping -InstallJsonPath $InstallJsonPath } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 9a-10 — Credential-sensitive phases (wrapped in try/catch for early cleanup)
    # SSO session expiry check before credential phases
    Invoke-WhatIfGuard -Message "Verify AWS SSO session validity before credential phases" -ScriptBlock {
        if (-not $SkipAWSLogin) {
            try {
                $ssoValid = Test-AwsSessionValidity -Profile $SsoProfile -ErrorAction SilentlyContinue -ErrorVariable ssoValidErr
                if ($ssoValidErr) { Write-SetupLog "SSO session validity probe reported errors: $($ssoValidErr[0].Exception.Message)" -Level WARN }
                if (-not $ssoValid) {
                    Write-SetupLog "AWS SSO session expired before credential phases — refreshing" -Level WARN
                    $refreshRegion = if ($Sovereignty) { $Sovereignty.SecretsRegion } else { "ca-central-1" }
                    $script:SsoProfile = Initialize-AwsSsoSession -SsoProfile $SsoProfile -SecretsRegion $refreshRegion -NonInteractive
                }
            } catch {
                Write-SetupLog "SSO session check before credential phases failed: $_ — proceeding with cached profile" -Level WARN
            }
        }
    } -WhatIf $WhatIf

    try {
        # PHASE 9a - IAM + Bedrock
        $script:CompletedPhases = Invoke-DeployPhase -PhaseName "IamAndBedrock" -ScriptBlock {
            Invoke-DeployPhaseIamAndBedrock -SsoProfile $SsoProfile -Sovereignty $Sovereignty -ProjectCode $ProjectCode -AgentRoles $Identity.AgentRoles -RoleNameMap $RoleNameMap -PSScriptRoot $PSScriptRoot -RepoRoot $RepoRoot -InstallOpencode $InstallOpencode -InstallBookkeeping $InstallBookkeeping -InstallJsonPath $InstallJsonPath -AgentConfigsRef ([ref]$script:AgentConfigs) -GatewayTokenRef ([ref]$script:GatewayToken)
        } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

        # PHASE 9b - Orchestrator Infrastructure
        $script:CompletedPhases = Invoke-DeployPhase -PhaseName "OrchestratorInfrastructure" -ScriptBlock { Invoke-DeployPhaseOrchestratorInfra -InstallAws "true" -AgentConfigs $script:AgentConfigs -SsoProfile $SsoProfile -Sovereignty $Sovereignty } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

        # PHASE 9c - Credential Isolation
        $script:CompletedPhases = Invoke-DeployPhase -PhaseName "CredentialIsolationTests" -ScriptBlock { Invoke-DeployPhaseCredentialIsolation -InstallAws "true" -AgentConfigs $script:AgentConfigs -SsoProfile $SsoProfile } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

        # PHASE 10 - Docker Secrets
        $script:CompletedPhases = Invoke-DeployPhase -PhaseName "DockerSecrets" -ScriptBlock {
            Invoke-DeployPhaseDockerSecrets -SsoProfile $SsoProfile -ProjectCode $ProjectCode -GatewayToken $script:GatewayToken -InstallOpencodeRef ([ref]$global:InstallOpencode) -HasCodingKeysRef ([ref]$script:HasCodingKeys) -AgentNumber $Identity.AgentNumber -InstallFleet $InstallFleet -InstallTailscale $InstallTailscale -InstallBrowserless $InstallBrowserless
        } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot
    } catch {
        Add-SetupError -Phase "DeployCredentialScope" -Message "Credential phase block failed: $_" -Category "Phase"
        Write-SetupLog "Credential phase failure — running credential cleanup before re-throw" -Level WARN
        try { Invoke-CredentialCleanup } catch { Write-SetupLog "Credential cleanup failed: $_" -Level WARN }
        throw
    }

    # PHASE 10.5 - Fleet Preflight (hydration readiness check)
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "FleetPreflight" -ScriptBlock {
        Write-SetupLog "FleetPreflight: verifying secret hydration readiness before deployment"
        $hydrationResults = Test-HydrationReadiness -CheckAws -SsoProfile $SsoProfile -SecretsRegion $Sovereignty.SecretsRegion -ProjectCode $ProjectCode
        $failed = $hydrationResults | Where-Object { -not $_.Passed }
        if ($failed.Count -gt 0) {
            $failedDetails = ($failed | ForEach-Object { "  [$($_.Check)] $($_.Detail) — Remediation: $($_.Remediation)" }) -join "`n"
            Write-SetupLog "FleetPreflight FAILED: $($failed.Count) secret(s) unresolved" -Level ERROR
            Write-Information -MessageData "  [FAIL] Secret hydration preflight: $($failed.Count) required secret(s) unresolved:" -Tags "ERROR"
            $failed | ForEach-Object { Write-Information -MessageData "    $($_.Check): $($_.Detail)" -Tags "WARN" }
            $missingNames = ($failed | ForEach-Object { $_.Check }) -join "`, "
            Write-Information -MessageData "  Missing secrets: $missingNames — check AWS SM $($Sovereignty.SecretsRegion) for these entries and verify SSO profile '$SsoProfile' has secrets:read access" -Tags "ERROR"
            Write-SetupLog "Partial hydration detected — $($failed.Count) unresolved out of $($hydrationResults.Count): $missingNames" -Level ERROR
            throw "FleetPreflight: $($failed.Count) required secrets could not be resolved: $missingNames — review errors above and ensure all AWS SM secrets exist before FleetDeploy"
        }
        Write-SetupLog "FleetPreflight: all $($hydrationResults.Count) secret checks passed"
        Write-Information -MessageData "  [OK] All secret hydration checks passed ($($hydrationResults.Count) total)." -Tags "INFO"
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 11 - Fleet Deployment (with health-aware retry)
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "FleetDeploy" -ScriptBlock {
        $deployAttempt = 0
        $deployMaxAttempts = [math]::Max(1, $DeployRetries + 1)
        $stackName = $ProjectCode
        if ([string]::IsNullOrWhiteSpace($stackName)) { throw "FleetDeploy: ProjectCode is null — cannot determine stack name" }
        do {
            $deployAttempt++
            if ($deployAttempt -gt 1) {
                Write-Information -MessageData "`n[Retry $($deployAttempt-1)/$DeployRetries] Redeploying fleet stack..." -Tags "WARN"
                Write-SetupLog "FleetDeploy retry $($deployAttempt-1)/$DeployRetries"
                # Retry cooldown — give Swarm time to settle failed service tasks before the next deploy attempt.
                Start-Sleep -Seconds 10
            }
            Write-Information -MessageData "`n[FleetDeploy] Deploying stack (attempt $deployAttempt)..." -Tags "INFO"

            try {
                Invoke-DeployPhaseFleetDeploy -BuildContext $script:BuildContext -RepoRoot $RepoRoot -AgentConfigs $script:AgentConfigs -ProjectCode $ProjectCode -InstallTailscale $InstallTailscale -InstallFleet $InstallFleet -InstallWorkspaceRepos $InstallWorkspaceRepos -InstallBrowserless $InstallBrowserless -InstallBookkeeping $InstallBookkeeping -InstallHermes $global:InstallHermes -SovereigntyTier $Sovereignty.Tier
            } catch {
                if ($deployAttempt -lt $deployMaxAttempts) {
                    Write-Information -MessageData "  [Retry] Deploy attempt $deployAttempt failed: $($_.Exception.Message)" -Tags "WARN"
                    $script:BuildContext = $null
                    continue
                }
                throw
            }

            # Post-deploy monitoring — wait for all services to reach 1/1 or Running
            Write-Information -MessageData "  [Monitor] Waiting for services to stabilize..." -Tags "INFO"
            $monitorTimeout = [datetime]::UtcNow.AddMinutes(5)
            $allStable = $false
            $monitorUncertain = $false
            while (-not $allStable -and [datetime]::UtcNow -lt $monitorTimeout) {
                # Monitoring poll interval — services take seconds to report replica counts after deploy.
                Start-Sleep -Seconds 15
                $svcResult = docker stack services $stackName --format "{{.Name}}`t{{.Replicas}}" 2>&1
                $svcExitCode = $LASTEXITCODE
                $parseableLines = @($svcResult | Where-Object { $_ -match "`t\d+/\d+$" })
                if ($svcExitCode -ne 0 -or $parseableLines.Count -eq 0) {
                    Write-SetupLog "FleetDeploy monitor: docker stack services query failed or returned no parseable replica lines (exit $svcExitCode) — cycle non-stable" -Level WARN
                    Write-Information -MessageData "  [WARN] docker stack services query failed — service stability unknown" -Tags "WARN"
                    $monitorUncertain = $true
                    $allStable = $false
                    continue
                }
                $allStable = $true
                foreach ($__line in $parseableLines) {
                    if ([string]::IsNullOrWhiteSpace($__line)) { continue }
                    $__parts = $__line -split "`t"
                    if ($__parts.Count -lt 2) { continue }
                    $__svcName = $__parts[0] -replace "^${stackName}_", ""
                    $__replicas = $__parts[1]
                    if ($__replicas -notmatch "^\d+/\d+$") { continue }
                    $active = [int]($__replicas -split '/')[0]
                    $desired = [int]($__replicas -split '/')[1]
                    if ($active -lt $desired) { $allStable = $false }
                }
            }

            # Check critical services — attempt auto-remediation if unstable
            $criticalSvc = docker stack services $stackName --format "{{.Name}}`t{{.Replicas}}" 2>&1
            $criticalExitCode = $LASTEXITCODE
            $criticalLines = @($criticalSvc | Where-Object { $_ -match "`t\d+/\d+$" })
            $criticalScanFailed = ($criticalExitCode -ne 0 -or $criticalLines.Count -eq 0)
            $unhealthyCritical = New-Object System.Collections.ArrayList
            foreach ($__line in $criticalLines) {
                if ([string]::IsNullOrWhiteSpace($__line)) { continue }
                $__parts = $__line -split "`t"
                if ($__parts.Count -lt 2) { continue }
                $__svcName = $__parts[0] -replace "^${stackName}_", ""
                $__replicas = $__parts[1]
                if ($__svcName -in @('is-fleet', 'mcp_opencode') -and $__replicas -match "^0/") {
                    [void]$unhealthyCritical.Add($__svcName)
                }
            }
            if ($criticalScanFailed) {
                Write-SetupLog "FleetDeploy monitor: critical-service scan failed or returned no parseable lines (exit $criticalExitCode) — status unknown" -Level WARN
                Write-Information -MessageData "  [WARN] Critical-service scan failed — status unknown" -Tags "WARN"
            }

            if (($monitorUncertain -or $criticalScanFailed) -and $deployAttempt -lt $deployMaxAttempts) {
                Write-Information -MessageData "  [Retry] Replica verification uncertain (attempt $deployAttempt/$deployMaxAttempts) — redeploying" -Tags "WARN"
                Write-SetupLog "FleetDeploy retry: replica verification uncertain — redeploying (attempt $deployAttempt)" -Level WARN
                continue
            } elseif ($monitorUncertain -or $criticalScanFailed) {
                Write-SetupLog "FleetDeploy FAILED after $deployAttempt attempts: docker stack services could not be queried" -Level ERROR
                Write-Information -MessageData "  [FAIL] Could not verify service replicas after $deployAttempt attempts (docker stack services failing)" -Tags "ERROR"
                throw "Fleet deployment verification failed: docker stack services could not be queried after $deployAttempt attempts"
            } elseif ($unhealthyCritical.Count -gt 0 -and $deployAttempt -lt $deployMaxAttempts) {
                Write-Information -MessageData "  [Remediate] Critical services unstable: $($unhealthyCritical -join ', ')" -Tags "WARN"
                Write-SetupLog "FleetDeploy remediation: $($unhealthyCritical -join ', ') have 0 replicas" -Level WARN
                foreach ($__svc in $unhealthyCritical) {
                    $__fullName = "${stackName}_${__svc}"
                    Write-Information -MessageData "    Purging stale healthcheck on $__fullName..." -Tags "INFO"
                    $null = docker service update --health-cmd="" $__fullName 2>&1
                    # Healthcheck purge propagation — Swarm needs a beat to register the update before the next one.
                    Start-Sleep -Seconds 5
                }
                Write-Information -MessageData "    Waiting 30s for services to recover..." -Tags "INFO"
            } elseif ($unhealthyCritical.Count -gt 0) {
                $failedList = $unhealthyCritical -join ", "
                $detail = docker service ps ($unhealthyCritical.ToArray() | ForEach-Object { "${stackName}_$_" }) --format "{{.Name}} {{.CurrentState}} {{.Error}}" --no-trunc 2>&1
                Write-SetupLog "FleetDeploy FAILED after $deployAttempt attempts: $failedList still at 0 replicas" -Level ERROR
                Write-Information -MessageData "  [FAIL] Critical services still at 0 replicas after $deployAttempt attempts:" -Tags "ERROR"
                if ($detail) { $detail | ForEach-Object { Write-Information -MessageData "    $_" -Tags "WARN" } }
                throw "Fleet deployment verification failed: $failedList still at 0 replicas after $deployAttempt attempts"
            } else {
                Write-Information -MessageData "  [OK] All services stable." -Tags "INFO"
                break
            }
        } while ($deployAttempt -lt $deployMaxAttempts)
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 12 - Configuration Persist
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "ConfigSave" -ScriptBlock { Save-InstanceConfiguration -InstallJsonPath $InstallJsonPath -ProjectCode $ProjectCode -AgentNumber $Identity.AgentNumber -RoleArray $Identity.RoleArray -AgentConfigs $script:AgentConfigs -SovereigntyTier $Sovereignty.Tier -InstallTailscale $InstallTailscale -InstallFleet $InstallFleet -InstallOpencode $InstallOpencode -InstallRekognitionFallback $InstallRekognitionFallback -InstallBrowserless $InstallBrowserless -InstallBookkeeping $InstallBookkeeping -InstallWorkspaceRepos $InstallWorkspaceRepos -SsoProfile $SsoProfile -SecretsRegion $Sovereignty.SecretsRegion } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 13 - Identity Configuration
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "IdentityConfig" -ScriptBlock {
        $configScript = Join-Path $PSScriptRoot "config.ps1"; & $configScript -SkipAWSLogin:$SkipAWSLogin -Project $ProjectCode -NonInteractive
        $configExitCode = $LASTEXITCODE; if ($configExitCode -ne 0) { Add-SetupError -Phase "IdentityConfig" -Message "config.ps1 exited with code $configExitCode" -Category "Phase"; throw "config.ps1 exited with code $configExitCode — identity configuration failed" }
    } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # PHASE 14 - Cleanup
    $script:CompletedPhases = Invoke-DeployPhase -PhaseName "Cleanup" -Recoverable:$true -ScriptBlock { Invoke-CredentialCleanup; Invoke-VhdCompaction -DroneMode:$DroneMode } -PhaseDependencies $PhaseDependencies -CompletedPhases $script:CompletedPhases -SelectedPhase $script:SelectedPhase -TagOnly $script:TagOnly -WhatIf $WhatIf -PSScriptRoot $PSScriptRoot

    # Final health verification — fail fast if fleet is unhealthy
    $healthFailCount = Invoke-FleetHealthCheck -Mode check -Parallel:$true
    if ($null -eq $healthFailCount) { $healthFailCount = 1; Write-SetupLog "Health check returned no result — treating as failure" -Level WARN }
    if ($healthFailCount -gt 0) {
        Write-SetupLog "Post-deploy health check detected $healthFailCount failures — deployment degraded" -Level WARN
        Write-Information -MessageData "  [WARN] $healthFailCount health checks failed — review above for details." -Tags "WARN"
    } else {
        Write-Information -MessageData "  [OK] All fleet health checks passed." -Tags "INFO"
    }

    Write-SetupLog "ORCHESTRATOR COMPLETE - $($Identity.AgentNumber) agent(s) deployed"
    Write-Information -MessageData "`n--- ORCHESTRATOR COMPLETE ---" -Tags "INFO"
} catch {
    Write-SetupLog "$ScriptName FAILED: $($_.Exception.Message)" -Level ERROR
    Write-Information -MessageData "`n[FATAL] $($_.Exception.Message)" -Tags "ERROR"
    Write-Information -MessageData "  Setup log: $SetupLogPath" -Tags "WARN"
    throw
} finally {
    Export-SetupErrors
}
