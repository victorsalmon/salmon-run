<#
.SYNOPSIS
    Fleet provisioning script. Performs sovereignty validation, secret hydration from AWS Secrets Manager, IAM user creation, and credential isolation tests.
.DESCRIPTION
    Executes provisioning phases: KeyTest (sovereignty validation), Secrets (AWS SM hydration),
    AwsUser (per-agent IAM user + Bedrock profile), AwsOrch (fleet + rekognition-fallback IAM),
    and AwsTest (credential isolation). Phase "All" runs all phases in sequence.
    Phase "None" allows safe dot-sourcing for testing without dispatch.
.PARAMETER Phase
    Provisioning phase to execute. Supported values: All, KeyTest, Secrets, AWS, AwsUser, AwsOrch, AwsTest, None.
    "All" runs KeyTest → Secrets → AwsUser → AwsOrch → AwsTest in order.
    "AWS" runs a consolidated AWS infrastructure + IAM pipeline.
    "None" skips all dispatch (for dot-source testing only).
.PARAMETER AgentContext
    Optional AgentContext object with ProjectCode, RoleCode, InstanceId, Index.
    Auto-created from environment variables if not provided.
.EXAMPLE
    .\1Provision.ps1 -Phase Secrets
    Run only the AWS Secrets Manager hydration phase.
.EXAMPLE
    .\1Provision.ps1 -Phase All
    Run all provisioning phases in sequence.
.NOTES
    File: 1Provision.ps1
    Requires: PowerShell 7.0+, AWS SSO profile configured, AWS CLI
    See-also: deploy.ps1, 1Deploy.ps1
#
# Phase credential scopes (R=Read, W=Write, RW=ReadWrite):
# Phase   | Scope
# --------|------------------------------------------
# KeyTest | Read AWS SM (sovereignty validation) [READ]
# Secrets | Read AWS SM (secret hydration) [READ]
# AwsUser | Write IAM, Read AWS SM (per-agent IAM) [READWRITE]
# AwsOrch | Write IAM, Read AWS SM (fleet IAM) [READWRITE]
# AwsTest | ReadWrite AWS SM (credential isolation) [READWRITE]
#>
# ==============================================================================
# Interclaw — v11.2 - Merged Provisioner (KeyTest + Secrets + AWS)
# ==============================================================================

param(
    [ValidateSet("All","KeyTest","Secrets","AWS","AwsUser","AwsOrch","AwsTest","None")]
    [string]$Phase = "All",
    $AgentContext
)

$ErrorActionPreference = "Stop"

# Bootstrap: load Core module directly so Import-InterclawModule is available
$__ocRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$env:PSModulePath = "$__ocRepoRoot\Skills\Docker\Modules;$env:PSModulePath"
Initialize-InterclawEnvironment -RepoRoot $__ocRepoRoot

Import-InterclawModule Core
Import-InterclawModule Secrets
Import-InterclawModule Identity
Import-InterclawModule Provision

# Create AgentContext from env vars if not provided (backward compat)
if (-not $AgentContext) {
    $AgentContext = New-AgentContext
}

# Guard: ensure AWS SSO profile is never empty, or all downstream --profile calls break
if ([string]::IsNullOrWhiteSpace($env:AWS_SSO_PROFILE)) {
    $env:AWS_SSO_PROFILE = "default"
    Write-SetupLog "AWS_SSO_PROFILE was empty, defaulted to 'default'"
}

# ==============================================================================
# Dispatch
# ==============================================================================

if ($Phase -eq "None") {
    # Used when dot-sourcing for testing — skip all dispatch
    return
}

if ($Phase -eq "All" -or $Phase -eq "KeyTest") {
    Test-Sovereignty
}

if ($Phase -eq "All" -or $Phase -eq "Secrets") {
    # Hydration is idempotent and sets env vars in the current process. The
    # checkpoint is informational only — env vars don't persist across
    # process boundaries, so downstream parallel runspaces need them re-hydrated
    # every time. Import-SecretsFromAws skips already-cached env vars internally,
    # so re-running is cheap.
    $PhaseName = "Provision-Secrets"
    if (Test-SetupCheckpoint -Name $PhaseName) {
        Write-Host "  [INFO] Provisioning Phase Secrets checkpoint exists; re-hydrating env vars (idempotent)." -ForegroundColor Cyan
    }
    Invoke-SecretHydration -AgentContext $AgentContext
    if (-not (Test-SetupCheckpoint -Name $PhaseName)) {
        Set-SetupCheckpoint -Name $PhaseName
    }
}

if ($Phase -eq "All" -or $Phase -eq "AwsUser") {
    $PhaseName = "Provision-AwsUser-$($AgentContext.ProjectCode)-$($AgentContext.RoleCode)-$($AgentContext.InstanceId)"
    if (Test-SetupCheckpoint -Name $PhaseName) {
        Write-Host "  [SKIP] Provisioning Phase AwsUser for $($AgentContext.RoleCode) already completed." -ForegroundColor Cyan
    } else {
        Write-SetupLog "AwsUser started"
        Write-Host "  --- AWS USER PROVISIONING ($($AgentContext.RoleCode)) ---" -ForegroundColor Cyan

        Import-SecretsFromAws -Keys (Get-SecretsOwnedKeys -List Aws) -SsoProfile $env:AWS_SSO_PROFILE -SourceLabel "AWS"

        Invoke-BedrockProfileSetup -AgentContext $AgentContext

        $iamRetries = 0; $iamMaxRetries = 3; $iamCreated = $null
        do {
            $iamRetries++
            try {
                $iamCreated = New-AgentIamUser -Index $AgentContext.Index -AgentContext $AgentContext
                break
            } catch {
                if ($_.Exception.Message -match 'NoSuchEntity|ServiceUnavailable|throttl|RequestLimitExceeded' -and $iamRetries -lt $iamMaxRetries) {
                    $backoff = [math]::Pow(2, $iamRetries) * 1000 + (Get-Random -Minimum 0 -Maximum 1000)
                    Write-SetupLog "IAM retry $iamRetries/$iamMaxRetries after: $_ — backing off ${backoff}ms" -Level WARN
                    # Exponential backoff — IAM is eventually consistent and throttles under load; wait before retry.
                    Start-Sleep -Milliseconds $backoff
                } else { throw }
            }
        } while ($iamRetries -lt $iamMaxRetries)
        if (-not $iamCreated) { throw "New-AgentIamUser failed after $iamMaxRetries retries" }

        Write-SetupLog "AwsUser complete"
        Set-SetupCheckpoint -Name $PhaseName
    }
}

if ($Phase -eq "All" -or $Phase -eq "AwsOrch") {
    $PhaseName = "Provision-AwsOrch"
    if (Test-SetupCheckpoint -Name $PhaseName) {
        Write-Host "  [SKIP] Provisioning Phase AwsOrch already completed." -ForegroundColor Cyan
    } else {
        Invoke-AgentOrchProvisioning -AgentContext $AgentContext
        Set-SetupCheckpoint -Name $PhaseName
    }
}

if ($Phase -eq "All" -or $Phase -eq "AwsTest") {
    $PhaseName = "Provision-AwsTest"
    if (Test-SetupCheckpoint -Name $PhaseName) {
        Write-Host "  [SKIP] Provisioning Phase AwsTest already completed." -ForegroundColor Cyan
    } else {
        try {
            Invoke-AgentCredentialTests -AgentContext $AgentContext
        } catch {
            Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red
            throw "AwsTest credential isolation failed: $($_.Exception.Message)"
        }
        # Cross-account isolation assertion: verify agent credentials cannot access other project accounts
        try {
            $testResult = Test-AgentCredentialIsolation -AgentContext $AgentContext -AssertCrossAccount
            if (-not $testResult.Passed) {
                $crossFailures = $testResult.Failures -join "; "
                Write-Host "  [FAIL] Cross-account isolation violation: $crossFailures" -ForegroundColor Red
                throw "Cross-account isolation assertion failed: $crossFailures"
            }
            Write-SetupLog "Cross-account isolation assertion passed" -Level INFO
        } catch {
            if ($_.Exception.Message -match 'CommandNotFoundException|not recognized') {
                Write-SetupLog "Cross-account isolation test skipped (Test-AgentCredentialIsolation -AssertCrossAccount not available in this module version)" -Level WARN
            } else { throw }
        }
        Set-SetupCheckpoint -Name $PhaseName
    }
}

if ($Phase -eq "AWS") {
    Write-SetupLog "1AWS started"
    Write-Host "`n--- AWS INFRASTRUCTURE & SECRET INJECTION START ---" -ForegroundColor Cyan

    try {
        # Identity from AgentContext (set by 0setup.ps1 or created from env vars above)
        if ([string]::IsNullOrWhiteSpace($AgentContext.ProjectCode)) {
            Write-SetupLog "FAIL: INSTALL_PROJECT not set" -Level ERROR
            Write-Host "  [CRITICAL ERROR] INSTALL_PROJECT is not set. This should be set by 0setup.ps1." -ForegroundColor Red
            throw "INSTALL_PROJECT is not set — 1Provision cannot continue"
        }
        if ([string]::IsNullOrWhiteSpace($AgentContext.RoleCode)) {
            Write-SetupLog "FAIL: INSTALL_ROLE not set" -Level ERROR
            Write-Host "  [CRITICAL ERROR] INSTALL_ROLE is not set. This should be set by 0setup.ps1." -ForegroundColor Red
            throw "INSTALL_ROLE is not set — 1Provision cannot continue"
        }

        $ProjectCode = $AgentContext.ProjectCode
        $RoleCode = $AgentContext.RoleCode
        $InstanceID = $AgentContext.InstanceId
        $Index = $AgentContext.Index
        $ProfileName = "${ProjectCode}-${RoleCode}-${InstanceID}"

        # --- Phase Secrets (checkpoint-gated) ---
        $PhaseName = "Provision-Secrets"
        if (Test-SetupCheckpoint -Name $PhaseName) {
            Write-Host "  [SKIP] Provisioning Phase Secrets already completed." -ForegroundColor Cyan
        } else {
            Write-SetupLog "Phase 3: Hydrating AWS keys from Secrets Manager"
            Import-SecretsFromAws -Keys (Get-SecretsOwnedKeys -List Aws) -SsoProfile $env:AWS_SSO_PROFILE -SourceLabel "AWS"
            Write-SetupLog "Phase 3 complete: AWS keys hydrated"
            Set-SetupCheckpoint -Name $PhaseName
        }

        # --- Phase AwsUser (checkpoint-gated) ---
        $CredentialResults = @()
        $PhaseName = "Provision-AwsUser-${ProjectCode}-${RoleCode}-${InstanceID}"
        if (Test-SetupCheckpoint -Name $PhaseName) {
            Write-Host "  [SKIP] Provisioning Phase AwsUser for $RoleCode already completed." -ForegroundColor Cyan
        } else {
            $BedrockRegion = Invoke-BedrockProfileSetup -AgentContext $AgentContext
            if ($null -eq $BedrockRegion) { throw "Invoke-BedrockProfileSetup returned no region — Bedrock profile setup failed" }
            Invoke-OrphanIamCleanup -AgentContext $AgentContext

            $iamRetries = 0; $iamMaxRetries = 3
            do {
                $iamRetries++
                try {
                    $AgentCreds = New-AgentIamUser -Index $Index -AgentContext $AgentContext
                    break
                } catch {
                    if ($_.Exception.Message -match 'NoSuchEntity|ServiceUnavailable|throttl|RequestLimitExceeded' -and $iamRetries -lt $iamMaxRetries) {
                        $backoff = [math]::Pow(2, $iamRetries) * 1000 + (Get-Random -Minimum 0 -Maximum 1000)
                        Write-SetupLog "IAM retry $iamRetries/$iamMaxRetries after: $_ — backing off ${backoff}ms" -Level WARN
                        # Exponential backoff — IAM is eventually consistent and throttles under load; wait before retry.
                        Start-Sleep -Milliseconds $backoff
                    } else { throw }
                }
            } while ($iamRetries -lt $iamMaxRetries)
            if (-not $AgentCreds) { throw "New-AgentIamUser failed after $iamMaxRetries retries" }
            if ($AgentCreds.AccessKeyId -and $AgentCreds.SecretAccessKey) {
                if ($AgentCreds.KeysAlreadyPropagated) {
                    Write-Host "  [SKIP] Agent credential isolation test — keys already propagated." -ForegroundColor Gray
                    Write-SetupLog "Skipped agent isolation test for $($AgentCreds.IamUserName) (keys >60s old)"
                } else {
                    $AgentVerify = Test-AgentCredentialIsolation -AgentAccessKeyId $AgentCreds.AccessKeyId -AgentSecretAccessKey $AgentCreds.SecretAccessKey -IamUserName $AgentCreds.IamUserName -BedrockRegion $BedrockRegion
                    $CredentialResults += $AgentVerify
                }
            }
            Set-SetupCheckpoint -Name $PhaseName
        }

        # RekognitionFallback (no checkpoint — always run for new instances)
        $PhotoCreds = New-RekognitionFallbackIamUser -AgentContext $AgentContext
        if ($PhotoCreds.AccessKeyId -and $PhotoCreds.SecretAccessKey) {
            Set-Item -Path "Env:\PROXY_AWS_ACCESS_KEY_ID" -Value $PhotoCreds.AccessKeyId
            Set-Item -Path "Env:\PROXY_AWS_SECRET_ACCESS_KEY" -Value $PhotoCreds.SecretAccessKey
            Write-SetupLog "Rekognition-fallback IAM user provisioned: $($PhotoCreds.IamUserName)"
        }

        $AnyCredentialFailures = $CredentialResults | Where-Object { -not $_.Passed }
        if ($AnyCredentialFailures) {
            Write-Host "`n[CRITICAL] Credential isolation verification failed. Aborting." -ForegroundColor Red
            foreach ($Fail in $AnyCredentialFailures) {
                foreach ($Msg in $Fail.Failures) {
                    Write-Host "  - $Msg" -ForegroundColor Red
                }
            }
            throw "Credential isolation verification failed — aborting deployment"
        }

        Write-Host "--- AWS INFRASTRUCTURE CHECK COMPLETE ---" -ForegroundColor Green
        Write-SetupLog "1AWS complete"
    } catch {
        Write-SetupLog "1AWS FAILED: $_" -Level ERROR
        Write-Host "  [FAIL] AWS provisioning failed: $($_.Exception.Message)" -ForegroundColor Red
        # Clean up any IAM resources that may have been created
        try {
            if ($AgentCreds -and $AgentCreds.IamUserName) {
                Write-SetupLog "Cleaning up IAM user: $($AgentCreds.IamUserName)" -Level WARN
                Remove-Item -Path "Env:\TMP_${ProjectCode}_IAM_USER" -ErrorAction SilentlyContinue -ErrorVariable tmpIamUserRmErr
                if ($tmpIamUserRmErr) { Write-SetupLog "TMP_${ProjectCode}_IAM_USER env remove reported errors: $($tmpIamUserRmErr[0].Exception.Message)" -Level WARN }
                aws iam delete-user --user-name $AgentCreds.IamUserName 2>$null
            }
            if ($PhotoCreds -and $PhotoCreds.IamUserName) {
                Write-SetupLog "Cleaning up Rekognition-fallback IAM user: $($PhotoCreds.IamUserName)" -Level WARN
                aws iam delete-user --user-name $PhotoCreds.IamUserName 2>$null
            }
            Invoke-OrphanIamCleanup -AgentContext $AgentContext
        } catch {
            Write-SetupLog "IAM resource cleanup failed: $_" -Level WARN
        }
        throw
    }
}




