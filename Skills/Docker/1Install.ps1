<#
.SYNOPSIS
    First-time host provisioning. Installs Docker Desktop, Git, AWS CLI, and PowerShell 7 prerequisites on a fresh Windows machine.
.DESCRIPTION
    Validates Windows build version (requires 1903+ for WSL2), enables WSL2 and Virtual Machine Platform,
    installs prerequisites via winget (PowerShell 7, Git, AWS CLI, Docker Desktop, Tailscale),
    clones the Interclaw repository from ORCHESTRATOR_REPO_URL env var, configures AWS SSO bootstrap,
    sets up firewall rules, and waits for the Docker daemon to be ready. Self-elevates to Administrator.
.EXAMPLE
    pwsh -File 1Install.ps1
    Run full first-time provisioning with interactive prompts.
.EXAMPLE
    $env:ORCHESTRATOR_REPO_URL = "https://github.com/myfork/ORCHESTRATOR.git"; pwsh -File 1Install.ps1
    Provision using a custom repository fork.
.NOTES
    File: 1Install.ps1
    Requires: Windows 10 build 1903+, Administrator privileges
    See-also: deploy.ps1
#>
# ==============================================================================
# Interclaw — HOST PROVISIONER (v5.1)
# ==============================================================================
# Installs all prerequisites on a fresh Windows machine:
#   - WSL2 + Virtual Machine Platform
#   - PowerShell 7 (pwsh), Git, AWS CLI, Docker Desktop, Tailscale
#   - Docker Desktop WSL2 backend pre-configured
#   - Clones the intersite-orchestrator repo
#   - Prompts for install.json values in the repo root
#   - Waits for Docker daemon to be ready
# Does NOT handle authentication (SSO, secrets) — that belongs in 0setup.ps1.
# ==============================================================================
$ErrorActionPreference = "Stop"

# Bootstrap: load Core module directly so Import-InterclawModule is available
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PSModulePath = "$__ocRepoRoot\Skills\Docker\Modules;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $__ocRepoRoot

Import-InterclawModule Core

# Local constants (1Install.ps1 is standalone and cannot dot-source 0Helpers.ps1)
$InstallConstants = @{
    RestartDelaySec       = 10
    DockerDaemonMaxAttempts = 30
    DockerDaemonRetryIntervalSec = 5
}

# 0. Elevate for DISM/Winget if not already admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $Shell = if (Get-Command pwsh -ErrorAction SilentlyContinue -ErrorVariable pwshCmdErr) { "pwsh" } else { "powershell" }
    Write-SetupLog "Elevating to administrator"
    Start-Process $Shell -ArgumentList "-File `"$PSCommandPath`"" -Verb RunAs
    return
}
Write-SetupLog "Running as administrator"

Write-Host "--- ORCHESTRATOR HOST PROVISIONER START ---" -ForegroundColor Cyan
Write-SetupLog "1Install.ps1 started"

$HomeDir = (Get-Item ~).FullName
$InterclawConfigDir = Join-Path $HomeDir ".ORCHESTRATOR"
$RepoPath = Join-Path $HomeDir "intersite-orchestrator"
$InstallJsonPath = Join-Path $RepoPath "install.json"

# 1. Windows version check (WSL2 requires 10.0.1903+)
$WinVer = [System.Version]::Parse((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentVersion + "." + (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuildNumber)
if ($WinVer.Build -lt 1903) {
    Write-SetupLog -Message "Windows build $($WinVer.Build) detected. WSL2 requires build 1903+." -Level ERROR
    Write-Host "  Please update Windows before continuing." -ForegroundColor Red
    exit 1
}
Write-Host "  [OK] Windows build $($WinVer.Build) meets minimum (1903+)." -ForegroundColor Green
Write-SetupLog "Windows build $($WinVer.Build) meets minimum"

# 2. WSL2 / VM Platform
$NeedsRestart = $false
foreach ($Feature in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
    $featureState = (Get-WindowsOptionalFeature -Online -FeatureName $Feature -ErrorAction Stop).State
    if ($featureState -ne "Enabled") {
        Write-Host "  Enabling Windows feature: $Feature..." -ForegroundColor Yellow
        $null = Enable-WindowsOptionalFeature -Online -FeatureName $Feature -NoRestart -All -ErrorAction Stop -ErrorVariable enableFeatureErr
        if ($enableFeatureErr) { Write-SetupLog "Feature enable reported errors: $enableFeatureErr" -Level WARN }
        $NeedsRestart = $true
    }
}

Write-SetupLog "Checking Windows features: WSL2 + VM Platform"
# 3. Winget idempotent installs
$Apps = @(
    @{ Id = "Microsoft.PowerShell";       Name = "PowerShell 7"; Version = "7.4.*" },
    @{ Id = "Git.Git";                    Name = "Git"; Version = "2.*" },
    @{ Id = "Amazon.AWSCLI";              Name = "AWS CLI"; Version = "2.*" },
    @{ Id = "Docker.DockerDesktop";       Name = "Docker Desktop"; Version = "4.*" },
    @{ Id = "Tailscale.Tailscale";        Name = "Tailscale"; Version = "1.*" }
)

foreach ($App in $Apps) {
    Write-Host "  Checking $($App.Name)..." -ForegroundColor Gray -NoNewline
    $alreadyInstalled = $false
    $currentVersion = $null
    if ($App.Name -eq "Docker Desktop" -and (Get-Command docker -ErrorAction SilentlyContinue -ErrorVariable dockerCmdErr)) {
        $alreadyInstalled = $true
    }
    if (-not $alreadyInstalled) {
        try {
            $ListResult = Invoke-NativeCommand { winget list --id $App.Id -e --accept-source-agreements 2>&1 }
        } catch {
            $ListResult = $null
            Write-SetupLog "winget list failed for $($App.Id): $_" -Level WARN
        }
        $alreadyInstalled = $null -ne $ListResult -and $ListResult.Output -notmatch "No installed package" -and $ListResult.Success -and -not [string]::IsNullOrWhiteSpace($ListResult.Output)
        if ($alreadyInstalled) {
            $versionMatch = [regex]::Match($ListResult.Output, '(\d+\.\d+\.\d+|\d+\.\d+)')
            if ($versionMatch.Success) { $currentVersion = $versionMatch.Value }
        }
    }
    if ($alreadyInstalled) {
        if ($currentVersion) { Write-Host " already installed (v$currentVersion)." -ForegroundColor Green }
        else { Write-Host " already installed." -ForegroundColor Green }
        Write-SetupLog "$($App.Name) already installed (v$($currentVersion ?? 'unknown'))"
    } else {
        Write-Host " installing..." -ForegroundColor Cyan
        $installArgs = @("install", "--id", $App.Id, "--silent", "--accept-package-agreements", "--accept-source-agreements")
        try {
            $InstallResult = Invoke-NativeCommand { winget @installArgs 2>&1 }
        } catch {
            $InstallResult = $null
            Write-SetupLog "winget install failed for $($App.Id): $_" -Level WARN
        }
        if ($null -ne $InstallResult -and $InstallResult.Success) {
            Write-Host "    [OK] $($App.Name) installed." -ForegroundColor Green
            Write-SetupLog "$($App.Name) installed successfully"
            try {
                $verifyResult = Invoke-NativeCommand { winget list --id $App.Id -e --accept-source-agreements 2>&1 }
            } catch {
                $verifyResult = $null
                Write-SetupLog "winget verify failed for $($App.Id): $_" -Level WARN
            }
            $verifyFound = $null -ne $verifyResult -and $verifyResult.Output -notmatch "No installed package" -and $verifyResult.Success
            if (-not $verifyFound) {
                Write-Host "    [WARN] $($App.Name) install reported success but winget list does not find it — package ID may have changed." -ForegroundColor Yellow
                Write-SetupLog "$($App.Name): post-install verification failed (winget list returned no match for $($App.Id))" -Level WARN
            } else {
                Write-Host "    [OK] $($App.Name) verified after install." -ForegroundColor Green
                Write-SetupLog "$($App.Name): post-install verification OK"
            }
        } else {
            Write-Host "    [WARN] $($App.Name) install returned exit code $($InstallResult.ExitCode). Package ID '$($App.Id)' may be incorrect or winget source unavailable." -ForegroundColor Yellow
            Write-SetupLog "$($App.Name): install failed (exit $($InstallResult.ExitCode)) for package ID '$($App.Id)'" -Level WARN
        }
    }
}
Write-SetupLog "Winget installs complete"

# 3a. Verify PowerShell 7 is on PATH after installation
$PwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue -ErrorVariable pwshVerifyErr
if ($null -ne $PwshCmd) {
    try {
        $PwshVersion = & pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
    } catch {
        $PwshVersion = $null
        Write-SetupLog "pwsh version probe failed: $_" -Level WARN
    }
    Write-Host "`n  [OK] PowerShell $PwshVersion detected." -ForegroundColor Green
}
else {
    Write-Host "`n  [WARN] PowerShell 7 was installed but is not on PATH yet." -ForegroundColor Yellow
    Write-Host "  Please restart your terminal to refresh PATH, then re-run 0setup.ps1." -ForegroundColor Yellow
    Write-Host "  Alternatively, run: pwsh -File `"$PSCommandPath`"" -ForegroundColor Yellow
}

# 4. Clone the repo if it doesn't exist
if (-not (Test-Path $RepoPath)) {
    Write-Host "`n  Cloning intersite-orchestrator repository..." -ForegroundColor Yellow
    try {
        $CloneResult = Invoke-NativeCommand { git clone $($env:ORCHESTRATOR_REPO_URL ?? "https://github.com/ORCHESTRATOR/ORCHESTRATOR.git") $RepoPath 2>&1 }
    } catch {
        $CloneResult = $null
        Write-SetupLog "git clone failed: $_" -Level ERROR
    }
    if ($null -eq $CloneResult -or -not $CloneResult.Success) {
        Write-Host "  [FAIL] Could not clone the repository. Please check your internet connection." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [OK] Repository cloned to $RepoPath" -ForegroundColor Green
    Write-SetupLog "Repository cloned to $RepoPath"
}
else {
    Write-Host "`n  [OK] Repository already exists at $RepoPath" -ForegroundColor Green
    Write-SetupLog "Repository already exists at $RepoPath"
}

# 5. Create config directory and prompt for install.json values
# Idempotent create — New-Item -Force is TOCTOU-safe, no existence pre-check needed.
$null = New-Item -ItemType Directory -Path $InterclawConfigDir -Force -ErrorAction Stop -ErrorVariable configDirErr
if ($configDirErr) { Write-SetupLog "Config dir create reported errors: $configDirErr" -Level WARN }
if (-not (Test-Path $InstallJsonPath)) {
    Write-Host "`n  No install.json found. Let's configure your fleet identity." -ForegroundColor Cyan
    Write-Host "  Press Enter to accept the default value shown in brackets." -ForegroundColor Gray

    $ProjDefault = $env:INSTALL_PROJECT ?? "FRAD"
    $ProjVal = Read-Host "  Project code [$ProjDefault] "
    if ($null -eq $ProjVal -or [string]::IsNullOrWhiteSpace($ProjVal)) { $ProjVal = $ProjDefault }

    $AgentNumVal = Read-Host "  Number of agents to deploy [1] "
    if ($null -eq $AgentNumVal -or [string]::IsNullOrWhiteSpace($AgentNumVal)) { $AgentNumVal = "1" }

    $RoleVal = Read-Host "  Role codes, comma-separated (e.g. BASE) [BASE] "
    if ($null -eq $RoleVal -or [string]::IsNullOrWhiteSpace($RoleVal)) { $RoleVal = "BASE" }

    $roleList = ($RoleVal -split ',' | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
    $agentObjects = $roleList | ForEach-Object { @{ role = $_; name = "" } }

    $InstallConfig = @{
        version = "1.0"
        project = @{ code = $ProjVal; domainSuffix = ".clocklobster.com"; publicDomain = "" }
        fleet = @{ sovereignty = "global"; agents = $agentObjects }
        features = @{
            sentry        = @{ install = $true }
            tailscale     = @{ install = $false }
            docusign      = @{ install = $true }
            browserless   = @{ install = $false }
            opencode      = @{ install = $false }
            'api-proxy' = @{ install = $false }
            'rekognition-fallback' = @{ install = $false }
            Bookkeeper    = @{ install = $false }
            # cloudflared retired — no longer deployed
        }
        workspace = @{ repos = @() }
        runtime   = @{ runId = ""; rebuildInterclaw = $false }
    }
    $InstallConfig | Write-AtomicJson -Path $InstallJsonPath -Depth 10
    Write-Host "  [OK] Saved install.json to $InstallJsonPath" -ForegroundColor Green
    Write-SetupLog "Created install.json with project $ProjVal"
}
else {
    Write-Host "`n  [OK] install.json already exists — keeping your settings." -ForegroundColor Green
    Write-SetupLog "install.json already exists"
}

# 6. AWS SSO Bootstrap Configuration — write ~/.aws/config directly
$AwsConfigDir = Join-Path $HomeDir ".aws"
$AwsConfigPath = Join-Path $AwsConfigDir "config"
$AwsConfigNeeded = $false
$SsoProfile = "default"

if (-not (Test-Path $AwsConfigPath)) {
    $AwsConfigNeeded = $true
}
else {
    $AwsConfigContent = Get-Content $AwsConfigPath -ErrorAction SilentlyContinue -ErrorVariable awsConfigReadErr
    if ($awsConfigReadErr) { Write-SetupLog "Could not read existing ~/.aws/config: $($awsConfigReadErr[0].Exception.Message)" -Level WARN }
    $HasSsoSession = if ($null -ne $AwsConfigContent) { $AwsConfigContent | Where-Object { $_ -match '^\[sso-session' } } else { $null }
    if (-not $HasSsoSession) { $AwsConfigNeeded = $true }
}

if ($AwsConfigNeeded) {
    Write-Host "`n  [AWS SSO] Configure AWS SSO bootstrap parameters." -ForegroundColor Cyan
    Write-Host "  These are written directly to ~/.aws/config." -ForegroundColor Gray
    Write-Host "  Find your SSO start URL, account ID, and role name in the AWS IAM Identity Center console." -ForegroundColor Gray

    $SsoStartUrl = Read-Host "  AWS SSO Start URL (e.g. https://d-abcdef1234.awsapps.com/start)"
    $SsoAccountId = Read-Host "  AWS Account ID"
    $SsoRoleName = Read-Host "  SSO Role Name (Permission Set)"
    $SsoProfile = Read-Host "  SSO Profile name [default]"
    if ($null -eq $SsoProfile -or [string]::IsNullOrWhiteSpace($SsoProfile)) { $SsoProfile = "default" }
    $AwsRegion = Read-Host "  AWS Region [$($env:AWS_SECRETS_REGION ?? "ca-central-1")]"
    if ($null -eq $AwsRegion -or [string]::IsNullOrWhiteSpace($AwsRegion)) { $AwsRegion = $env:AWS_SECRETS_REGION ?? "ca-central-1" }

    if (-not [string]::IsNullOrWhiteSpace($SsoStartUrl) -and -not [string]::IsNullOrWhiteSpace($SsoAccountId)) {
        # Idempotent create — New-Item -Force is TOCTOU-safe, no existence pre-check needed.
        $null = New-Item -ItemType Directory -Path $AwsConfigDir -Force -ErrorAction Stop -ErrorVariable awsCfgDirErr
        if ($awsCfgDirErr) { Write-SetupLog "AWS config dir create reported errors: $awsCfgDirErr" -Level WARN }

        $AwsConfigContent = @"
[sso-session ORCHESTRATOR]
sso_start_url = $SsoStartUrl
sso_region = $AwsRegion
sso_registration_scopes = sso:account:access

[profile $SsoProfile]
sso_session = ORCHESTRATOR
sso_account_id = $SsoAccountId
sso_role_name = $SsoRoleName
region = $AwsRegion
"@
        $AwsConfigContent | Write-AtomicFile -Path $AwsConfigPath -Encoding utf8
        Write-Host "  [OK] Wrote SSO profile '$SsoProfile' to $AwsConfigPath" -ForegroundColor Green
        Write-SetupLog "AWS SSO config written for profile $SsoProfile"
    }
    else {
        Write-Host "  [WARN] SSO Start URL and Account ID are required for AWS provisioning. You can add them to ~/.aws/config later." -ForegroundColor Yellow
        Write-SetupLog "AWS SSO config skipped (missing parameters)" -Level WARN
    }
}
else {
    Write-Host "`n  [OK] ~/.aws/config already has an SSO session — keeping your settings." -ForegroundColor Green
    Write-SetupLog "AWS SSO config already exists"
}

# 7. Configure Docker Desktop WSL2 backend (write settings before first launch)
$DockerSettingsDir = Join-Path $HomeDir "AppData\Roaming\Docker"
$DockerSettingsPath = Join-Path $DockerSettingsDir "settings.json"

# Idempotent create — New-Item -Force is TOCTOU-safe, no existence pre-check needed.
$null = New-Item -ItemType Directory -Path $DockerSettingsDir -Force -ErrorAction Stop -ErrorVariable dockerCfgDirErr
if ($dockerCfgDirErr) { Write-SetupLog "Docker settings dir create reported errors: $dockerCfgDirErr" -Level WARN }

if (-not (Test-Path $DockerSettingsPath)) {
    Write-Host "`n  Configuring Docker Desktop for WSL2 backend..." -ForegroundColor Yellow

    $DockerSettings = @{
        wslEngineEnabled = $true
        autoStart        = $false
        theme            = "dark"
    } | ConvertTo-Json -Depth 3

    $DockerSettings | Write-AtomicFile -Path $DockerSettingsPath -Encoding UTF8
    Write-Host "  [OK] Docker Desktop configured for WSL2 backend." -ForegroundColor Green
    Write-SetupLog "Docker Desktop WSL2 backend configured"
}

# 7a. Harden Windows Firewall — block inbound ORCHESTRATOR gateway ports on Private profile
# Gateway agents bind to 0.0.0.0 by default. This prevents LAN devices from reaching
# them directly while still allowing localhost and Tailscale access.
$FirewallRuleName = "Interclaw-Gateway-Inbound-Block"
$ExistingRule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue -ErrorVariable fwRuleErr
if ($fwRuleErr) { Write-SetupLog "Firewall rule lookup reported errors: $($fwRuleErr[0].Exception.Message)" -Level WARN }
if ($null -eq $ExistingRule) {
    Write-Host "`n  [SECURITY] Creating Windows Firewall rule to block inbound gateway ports on Private networks..." -ForegroundColor Yellow
    try {
        $reg = Get-PortRegistry
        $rangeStart = if ($null -ne $reg) { $reg.ranges.gateway_host_ports.start } else { 20100 }
        $rangeEnd   = if ($null -ne $reg) { $reg.ranges.gateway_host_ports.end } else { 39900 }
        New-NetFirewallRule `
            -DisplayName $FirewallRuleName `
            -Direction Inbound `
            -LocalPort "${rangeStart}-${rangeEnd}" `
            -Protocol TCP `
            -Action Block `
            -Profile Private `
            -Description "Blocks inbound access to ORCHESTRATOR gateway agent ports (${rangeStart}-${rangeEnd}) on Private networks. Access via Tailscale or localhost only." `
            -ErrorAction Stop -ErrorVariable fwCreateErr
        if ($fwCreateErr) { Write-SetupLog "Firewall rule create reported errors: $($fwCreateErr[0].Exception.Message)" -Level WARN }
        Write-Host "  [OK] Firewall rule '$FirewallRuleName' created — gateway ports blocked on Private profile." -ForegroundColor Green
        Write-SetupLog "Firewall rule $FirewallRuleName created"
    }
    catch {
        Write-Host "  [WARN] Could not create firewall rule: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SetupLog "Firewall rule creation failed: $($_.Exception.Message)" -Level WARN
    }
}
else {
    Write-Host "`n  [OK] Firewall rule '$FirewallRuleName' already exists." -ForegroundColor Green
    Write-SetupLog "Firewall rule $FirewallRuleName already exists"
}

# 8. Restart if WSL2 features were just enabled
if ($NeedsRestart) {
    Write-Host "`n  [RESTART REQUIRED] WSL2 features enabled. Restarting in $($InstallConstants.RestartDelaySec) seconds..." -ForegroundColor Red
    Write-Host "  0setup.ps1 will resume after restart via RunOnce." -ForegroundColor Yellow
    # Grace period for the user to read the restart warning before the machine reboots.
    Start-Sleep -Seconds ($InstallConstants.RestartDelaySec ?? 10)
    Restart-Computer
}

# 9. Wait for Docker daemon to be ready
# Ensure Docker CLI is on PATH and start Docker Desktop if not running
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue -ErrorVariable dockerCmdLookupErr
if ($dockerCmdLookupErr) { Write-SetupLog "Docker CLI lookup reported errors: $($dockerCmdLookupErr[0].Exception.Message)" -Level WARN }
$dockerBin = if ($null -ne $dockerCmd) { Split-Path $dockerCmd.Source -Parent } else { Join-Path $env:ProgramFiles (Join-Path "Docker" "Docker\resources\bin") }
if ($null -eq $dockerCmd) {
    Write-Host "  [WARN] Docker CLI not found on PATH — using fallback path: $dockerBin" -ForegroundColor Yellow
    Write-SetupLog "Docker CLI not on PATH, using fallback" -Level WARN
}
if ((Test-Path $dockerBin) -and ($env:PATH -notlike "*$dockerBin*")) {
    $env:PATH = "$dockerBin;$env:PATH"
    Write-Host "  [OK] Added Docker CLI to PATH: $dockerBin" -ForegroundColor Green
    Write-SetupLog "Docker CLI added to PATH"
}
$dockerProc = Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue -ErrorVariable dockerProcErr
if ($dockerProcErr) { Write-SetupLog "Docker Desktop process lookup reported errors: $($dockerProcErr[0].Exception.Message)" -Level WARN }
if ($null -eq $dockerProc) {
    Write-Host "  Starting Docker Desktop..." -ForegroundColor Yellow
    $dockerDesktopExe = if ($null -ne $dockerCmd) {
        Join-Path (Get-Item $dockerCmd.Source).Directory.Parent.Parent.FullName "Docker Desktop.exe"
    } else {
        Join-Path $env:ProgramFiles (Join-Path "Docker" "Docker\Docker Desktop.exe")
    }
    if (-not (Test-Path $dockerDesktopExe)) {
        Write-Host "  [WARN] Docker Desktop not found at $dockerDesktopExe — trying default path." -ForegroundColor Yellow
        $dockerDesktopExe = Join-Path $env:ProgramFiles (Join-Path "Docker" "Docker\Docker Desktop.exe")
    }
    Start-Process $dockerDesktopExe
    Write-SetupLog "Docker Desktop started"
}
Write-Host "`n  Waiting for Docker daemon to be ready..." -ForegroundColor Yellow
$DockerReady = $false
$Attempts = 0
$MaxAttempts = $InstallConstants.DockerDaemonMaxAttempts ?? 30

while (-not $DockerReady -and $Attempts -lt $MaxAttempts) {
    $Attempts++
    try {
        $Result = Invoke-NativeCommand { docker info 2>&1 }
        if ($null -ne $Result -and $Result.Success) {
            $DockerReady = $true
            Write-Host "  [OK] Docker daemon is ready." -ForegroundColor Green
            Write-SetupLog "Docker daemon ready after $Attempts attempts"
        }
    }
    catch {
        # Docker not ready yet
    }

    if (-not $DockerReady) {
        Write-Host "  Attempt $Attempts/$MaxAttempts — Docker not ready, waiting $($InstallConstants.DockerDaemonRetryIntervalSec)s..." -ForegroundColor Gray
        # Poll interval — Docker Desktop takes several seconds to start its daemon after launch.
        Start-Sleep -Seconds ($InstallConstants.DockerDaemonRetryIntervalSec ?? 5)
        if ($Attempts -eq 1 -or $Attempts -eq 10 -or $Attempts -eq 20) {
            Write-SetupLog "Docker daemon not ready after $Attempts attempts" -Level DEBUG
        }
    }
}

if (-not $DockerReady) {
    Write-Host "  [FAIL] Docker daemon did not become ready after $($MaxAttempts * ($InstallConstants.DockerDaemonRetryIntervalSec ?? 5)) seconds." -ForegroundColor Red
    Write-Host "  Please start Docker Desktop manually and re-run 0setup.ps1." -ForegroundColor Yellow
    Write-SetupLog "Docker daemon failed to become ready after $MaxAttempts attempts" -Level ERROR
    exit 1
}

# 9a. Register Docker Desktop boot task — replaces unreliable autoStart with
#     a scheduled task that resets WSL2 before starting Docker Desktop.
#     Also flip autoStart to false in settings.json for re-runs.
Write-Host "`n  Configuring Docker Desktop boot-time startup..." -ForegroundColor Yellow
try {
    Import-InterclawModule Host
    Register-DockerDesktopBootTask

    $CurrentSettings = Get-Content -Path $DockerSettingsPath -Raw | ConvertFrom-Json
    if ($null -ne $CurrentSettings -and $CurrentSettings.autoStart -ne $false) {
        $CurrentSettings.autoStart = $false
        $CurrentSettings | Write-AtomicJson -Path $DockerSettingsPath -Depth 3
        Write-Host "  [OK] Docker Desktop autoStart disabled in settings.json." -ForegroundColor Green
        Write-SetupLog "Docker Desktop autoStart set to false"
    }
}
catch {
    Write-Host "  [WARN] Could not register boot task: $_" -ForegroundColor Yellow
    Write-SetupLog "Boot task registration failed: $_" -Level WARN
}

# 10. Tailscale — verify installation (authentication handled by 0setup.ps1 after AWS SSO login)
$TailscaleCmd = Get-Command tailscale -ErrorAction SilentlyContinue -ErrorVariable tailscaleCmdErr
if ($null -ne $TailscaleCmd) {
    Write-Host "`n  [OK] Tailscale detected at $($TailscaleCmd.Source)" -ForegroundColor Green
    Write-Host "  Tailscale authentication will be performed by 0setup.ps1 after AWS SSO login." -ForegroundColor Gray
    Write-SetupLog "Tailscale installed at $($TailscaleCmd.Source)"
}
else {
    Write-Host "`n  [WARN] Tailscale was not found on PATH after installation." -ForegroundColor Yellow
    Write-Host "  A system restart may be required for PATH changes to take effect." -ForegroundColor Yellow
    if ($tailscaleCmdErr) { Write-SetupLog "Tailscale lookup reported errors: $($tailscaleCmdErr[0].Exception.Message)" -Level WARN }
    Write-SetupLog "Tailscale not on PATH after install" -Level WARN
}

Write-Host "`n--- ORCHESTRATOR HOST PROVISIONER COMPLETE ---" -ForegroundColor Cyan
Write-SetupLog "1Install.ps1 complete"