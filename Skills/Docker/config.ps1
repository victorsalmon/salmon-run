<#
.SYNOPSIS
    Identity configurator for Telegram pairing, AWS SSO, and owner placeholder setup.
#>
#Requires -Version 7.0
# ==============================================================================
# ORCHESTRATOR IDENTITY CONFIGURATOR (v1.0 — identity-only)
# ==============================================================================
param (
    [string]$Project,
    [string]$TelegramPairingCode,
    [switch]$NonInteractive,
    [switch]$SkipAWSLogin,
    [switch]$Force,
    [string]$ReconfigureService,
    [hashtable]$EnvOverrides = @{},
    [switch]$RestartService,
    [string]$RotateSecret,
    [string]$RotateSecretValue,
    [string[]]$RotateSecretServices,
    [string]$RebuildService,
    [switch]$RebuildImage,
    [switch]$RotateRekognitionFallbackKeys
)

$ScriptName = Split-Path -Leaf $PSCommandPath
$EnvOverrides = @{} + $EnvOverrides
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$PSNativeCommandArgumentPassing = 'Legacy'
Write-Verbose "Native command argument passing set to: $PSNativeCommandArgumentPassing"

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$HomeDir = if ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { "/home/node" }
$InterclawDir = Join-Path $HomeDir ".ORCHESTRATOR"

$__modulesDir = Join-Path $RepoRoot "Skills" "Docker" "Modules"
$env:PSModulePath = "$__modulesDir;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $RepoRoot

Import-InterclawModule Config

$LogPath = $env:INTERCLAW_SETUP_LOG
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $InterclawDir "config-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    $env:INTERCLAW_SETUP_LOG = $LogPath
}

# Dot-source config helpers (decomposed into focused, independently-testable scripts)
$__helpersDir = Join-Path $PSScriptRoot "config-helpers"
. (Join-Path $__helpersDir "config-shared.ps1")
. (Join-Path $__helpersDir "config-telegram.ps1")
. (Join-Path $__helpersDir "config-identity.ps1")
. (Join-Path $__helpersDir "config-services.ps1")
. (Join-Path $__helpersDir "config-rotation.ps1")

Write-SetupLog "$ScriptName started"

if ($ReconfigureService -or $RotateSecret -or $RebuildService) {
    Invoke-FleetOperationalCommand -ReconfigureService $ReconfigureService -EnvOverrides $EnvOverrides -RestartService:$RestartService -RotateSecret $RotateSecret -RotateSecretValue $RotateSecretValue -RotateSecretServices $RotateSecretServices -RebuildService $RebuildService -RebuildImage:$RebuildImage
    return
}

if ($RotateRekognitionFallbackKeys) {
    Write-Host "`n[CONFIG] Rotating rekognition-fallback AWS keys..." -ForegroundColor Cyan
    # Rotate AWS access keys for the rekognition-fallback IAM user.
    # Lifecycle:
    #   1. Create a new access key (AWS allows 2 keys per user)
    #   2. Push the new key to Fleet's rotation proxy
    #   3. Delete ALL old keys (including any pre-existing third key)
    # This ensures zero-downtime rotation — the old key remains valid
    # until the Fleet proxy switches to the new one.

    $projectCode = $env:INSTALL_PROJECT ?? (Get-DefaultProjectCode)
    $iamUser = "${projectCode}-REKOGNITIONFALLBACK"
    $newKey = Invoke-NativeCommand {
        aws iam create-access-key --user-name $iamUser --profile $env:AWS_SSO_PROFILE --output json 2>&1
    }
    if (-not $newKey.Success) {
        Write-Error "Failed to create new access key for $iamUser"
        exit 1
    }
    $key = $newKey.Output | ConvertFrom-Json

    # Key created. Now push to Fleet rotation proxy.
    # The proxy at :29998 accepts new credentials and swaps them
    # into the running rekognition-fallback container.
    $payload = @{
        proxy_aws_id = $key.AccessKey.AccessKeyId
        proxy_aws_secret = $key.AccessKey.SecretAccessKey
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "http://is-fleet:29998/rotate" `
        -Method Post -Body $payload -ContentType "application/json"

    if ($response.Success -or $response.status -eq "rotated") {
        Write-Host "  [OK] Rekognition-fallback keys rotated and verified" -ForegroundColor Green
    } else {
        Write-Error "Rotation failed: $($response.message)"
    }

    $existingKeys = aws iam list-access-keys --user-name $iamUser --profile $env:AWS_SSO_PROFILE --output json | ConvertFrom-Json
    $failedKeyIds = @()
    foreach ($old in $existingKeys.AccessKeyMetadata) {
        if ($old.AccessKeyId -ne $key.AccessKey.AccessKeyId) {
            $deleteResult = aws iam delete-access-key --user-name $iamUser --access-key-id $old.AccessKeyId --profile $env:AWS_SSO_PROFILE 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Failed to delete old rekognition access key $($old.AccessKeyId): $deleteResult"
                $failedKeyIds += $old.AccessKeyId
            } else {
                Write-Verbose "  Deleted old key: $($old.AccessKeyId)"
            }
        }
    }

    $remainingKeys = aws iam list-access-keys --user-name $iamUser --profile $env:AWS_SSO_PROFILE --output json | ConvertFrom-Json
    if ($remainingKeys.AccessKeyMetadata.Count -ge 2) {
        throw "Rekognition-fallback key cleanup failed: $($remainingKeys.AccessKeyMetadata.Count) keys remain ($($failedKeyIds -join ', ')) — AWS LimitExceeded will occur on next rotation"
    }

    Write-Host "  [OK] Rekognition-fallback key rotation complete" -ForegroundColor Green
    return
}

# Read install.json from the repo root via module path resolution.
# The function searches: $RepoRoot/install.json or
# $env:INSTALL_JSON_PATH fallback.
$InstallJson = Read-InstallJson
$Config = @{
    Project = $Project ?? $env:INSTALL_PROJECT ?? $InstallJson.project.code
}
if (-not $Config.Project) {
    if ($NonInteractive) { Write-SetupLog "Project is required" -Level ERROR; exit 1 }
    $DefaultExample = Get-DefaultProjectCode
    $Config.Project = Read-Host "Project code (e.g. $DefaultExample)"
    if (-not $Config.Project) { Write-SetupLog "Project is required" -Level ERROR; exit 1 }
}
$env:INSTALL_PROJECT = $Config.Project

Write-SetupLog "Project: $($Config.Project)"

# -----------------------------------------------------------------------
# PHASE 15 — Prerequisites
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "Prerequisites" -ScriptBlock {
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { throw "AWS CLI not found" }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker not found" }
}

# -----------------------------------------------------------------------
# PHASE 16 — Telegram Pairing (extracted to config-telegram.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "TelegramPairing" -ScriptBlock {
    Invoke-TelegramPairingPhase -TelegramPairingCode $TelegramPairingCode -NonInteractive:$NonInteractive -Force:$Force -ScriptName $ScriptName
}

# -----------------------------------------------------------------------
# PHASE 16b — ORCHESTRATOR Mobile App Pairing (extracted to config-telegram.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "MobileAppPairing" -Recoverable -ScriptBlock {
    Invoke-MobileAppPairingPhase -NonInteractive:$NonInteractive -ScriptName $ScriptName
}

# -----------------------------------------------------------------------
# PHASE 17 — AWS SSO (extracted to config-identity.ps1)
# -----------------------------------------------------------------------
# Load Provision + its required modules for Initialize-AwsSsoSession
Import-InterclawModule Constants
Import-InterclawModule Identity
Import-InterclawModule Secrets
Import-InterclawModule Provision

$global:AwsSsoProfile = $null
Invoke-LocalPhase -Phase "AwsSso" -ScriptBlock {
    Invoke-AwsSsoPhase
}

# -----------------------------------------------------------------------
# PHASE 18 — Owner Config (extracted to config-identity.ps1)
# -----------------------------------------------------------------------
$ownerPlaceholdersBefore = Get-OwnerPlaceholders
Invoke-LocalPhase -Phase "OwnerConfig" -ScriptBlock {
    Invoke-OwnerConfigPhase -NonInteractive:$NonInteractive -Force:$Force
}
$ownerPlaceholdersAfter = Get-OwnerPlaceholders
$ownerConfigChanged = $Force -or ($ownerPlaceholdersBefore.Count -eq 0 -and $ownerPlaceholdersAfter.Count -gt 0)

# -----------------------------------------------------------------------
# PHASE 18b — Auto-reseed after owner config changes
# -----------------------------------------------------------------------
if (-not $SkipAWSLogin -and $ownerConfigChanged) {
    Write-Host "`n[PHASE 18b] Reseeding agent config volumes with updated owner context..." -ForegroundColor Cyan
    try {
        $reseedsult = Invoke-AgentReseed -Restart -Force
        Write-Host "  [OK] Reseeded $($reseedsult.Succeeded)/$($reseedsult.Total) agent(s)" -ForegroundColor Green
        if ($reseedsult.Failed -gt 0) {
            Write-SetupLog -Message "$($reseedsult.Failed) agent(s) failed to reseed. Succeeded: $($reseedsult.Succeeded)" -Level WARN
        }
    } catch {
        Write-SetupLog -Message "Agent reseed failed: $($_.Exception.Message)" -Level WARN
    }
}

# -----------------------------------------------------------------------
# PHASE 19 — Browserless Configuration (extracted to config-services.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "BrowserlessConfig" -Recoverable -ScriptBlock {
    Invoke-BrowserlessPhase -NonInteractive:$NonInteractive -Force:$Force
}

# -----------------------------------------------------------------------
# PHASE 20 — DocuSign SMTP Configuration (extracted to config-services.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "DocusignSmtpConfig" -Recoverable -ScriptBlock {
    Invoke-DocusignPhase -NonInteractive:$NonInteractive -Force:$Force
}

# -----------------------------------------------------------------------
# PHASE 21 — Firecrawl & Tavily API Keys (Web MCP) (extracted to config-services.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "WebMcpApiKeys" -Recoverable -ScriptBlock {
    Invoke-WebMcpPhase -NonInteractive:$NonInteractive -Force:$Force
}

# -----------------------------------------------------------------------
# PHASE 22 — Coding Key ON-Flag State Check (extracted to config-rotation.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "CodingKeyOnFlagCheck" -Recoverable -ScriptBlock {
    Invoke-CodingKeyCheckPhase
}

# -----------------------------------------------------------------------
# PHASE 23 — Secret Rotation (from install.json rotate arrays) (extracted to config-rotation.ps1)
# -----------------------------------------------------------------------
Invoke-LocalPhase -Phase "SecretRotation" -Recoverable -ScriptBlock {
    Invoke-SecretRotationPhase
}

# -----------------------------------------------------------------------
# FINAL — Export errors if any (no output when clean)
# -----------------------------------------------------------------------
Export-SetupErrors

Write-Host "`n  IDENTITY CONFIGURATION COMPLETE" -ForegroundColor Cyan
Write-SetupLog "Identity configuration complete"
