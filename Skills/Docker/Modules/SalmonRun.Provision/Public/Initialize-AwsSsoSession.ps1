<#
.SYNOPSIS
    Initializes an AWS SSO session for use by all downstream scripts.
    Handles profile auto-detection from ~/.aws/config, session validity checks,
    cache corruption repair, SSO login, and session verification.
    Sets $env:AWS_SSO_PROFILE and $env:AWS_SECRETS_REGION on success.
    Designed to be idempotent '" if a valid session already exists, it returns immediately.
.PARAMETER SsoProfile
    The AWS SSO profile name. If not provided, auto-detected from ~/.aws/config.
.PARAMETER SecretsRegion
    The AWS region where secrets are stored. Defaults to "ca-central-1".
.PARAMETER NonInteractive
    If set, skips prompts and throws on expired session rather than opening a browser.
.PARAMETER SkipCacheRepair
    If set, skips the corrupted cache detection/repair step (Windows-only).
.OUTPUTS
    The resolved SSO profile name (string).
.EXAMPLE
    $Profile = Initialize-AwsSsoSession
    # Auto-detects profile, checks/refreshes session, sets env vars.
.EXAMPLE
    Initialize-AwsSsoSession -SsoProfile "my-profile" -NonInteractive
    # Uses pre-set profile, fails fast if session is expired (no browser login).
#>
function Initialize-AwsSsoSession {
    [OutputType([string])]
    param(
        [string]$SsoProfile,
        [string]$SecretsRegion = "ca-central-1",
        [switch]$NonInteractive,
        [switch]$SkipCacheRepair
    )

    $HomeDir = Get-HomeDir

    if ([string]::IsNullOrWhiteSpace($SsoProfile)) {
        $SsoProfile = $env:AWS_SSO_PROFILE
    }

    $AwsDir = Join-Path $HomeDir ".aws"
    if (-not (Test-Path $AwsDir) -and ($IsWindows -or $env:OS -eq "Windows_NT") -and $env:USERPROFILE) {
        $fallbackAwsDir = Join-Path $env:USERPROFILE ".aws"
        if (Test-Path $fallbackAwsDir) {
            $AwsDir = $fallbackAwsDir
        }
    }

    if ([string]::IsNullOrWhiteSpace($SsoProfile)) {
        $AwsConfigPath = Join-Path $AwsDir "config"
        if (Test-Path $AwsConfigPath) {
            $Profiles = @()
            Get-Content $AwsConfigPath | ForEach-Object {
                if ($_ -match '^\[profile\s+(.+)\]$') { $Profiles += $Matches[1] }
                elseif ($_ -match '^\[default\]$') { $Profiles += "default" }
            }
            $Profiles = @($Profiles | Where-Object { $_ -ne "sso-session" })

            if ($Profiles.Count -eq 1) {
                $SsoProfile = $Profiles[0]
                Write-SetupLog "Single AWS SSO profile detected: $SsoProfile"
            }
            elseif ($Profiles.Count -gt 1) {
                if ($NonInteractive) {
                    $SsoProfile = $Profiles[0]
                    Write-SetupLog "Multiple AWS profiles found, NonInteractive mode — using first: $SsoProfile"
                }
                else {
                    Write-Verbose "  Available AWS SSO profiles:"
                    for ($i = 0; $i -lt $Profiles.Count; $i++) {
                        Write-Verbose "    [$i] $($Profiles[$i])"
                    }
                    $Choice = Read-Host "  Select profile number"
                    $parsed = 0
                    if ([int]::TryParse($Choice, [ref]$parsed) -and $parsed -ge 0 -and $parsed -lt $Profiles.Count) {
                        $SsoProfile = $Profiles[$parsed]
                    }
                    else {
                        $SsoProfile = $Profiles[0]
                    }
                    Write-SetupLog "Selected AWS SSO profile: $SsoProfile"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($SsoProfile)) {
            $SsoProfile = "default"
            Write-SetupLog "No AWS profiles found in ~/.aws/config — using 'default'"
        }
    }

    Set-Item -Path "Env:\AWS_SSO_PROFILE" -Value $SsoProfile
    Set-Item -Path "Env:\AWS_SECRETS_REGION" -Value $SecretsRegion
    Write-SetupLog "AWS SSO profile: $SsoProfile  |  Secrets region: $SecretsRegion"

    $IdentityRegion = $env:AWS_REGION ?? $SecretsRegion

    $IdentityResult = Invoke-AwsCommand { aws sts get-caller-identity --profile $SsoProfile --region $IdentityRegion 2>&1 }
    if ($IdentityResult.Success) {
        $ProjectCode = Get-ProjectCode
        $SmResult = Invoke-AwsCommand { aws secretsmanager get-secret-value --secret-id "Interclaw/$ProjectCode/Provisioning" --query "SecretString" --output text --profile $SsoProfile --region $SecretsRegion 2>&1 }
        if ($SmResult.Success) {
            Write-SetupLog "SSO session already active for $SsoProfile"
            return $SsoProfile
        }
        $smOutput = $SmResult.Output -join "`n"
        if ($smOutput -match "AccessDenied|Unauthorized|not authorized") {
            Write-SetupLog "SSO session has NO Secrets Manager permission — get-caller-identity succeeded but AccessDenied on Secrets Manager. This is a missing IAM policy, NOT a stale token; re-login cannot fix it." -Level ERROR
            throw "AWS SSO role '$($SsoProfile)' is not authorized for Secrets Manager (AccessDenied). Attach a policy granting secretsmanager:ListSecrets/GetSecretValue to the role, then re-run. Underlying error: $($smOutput.Substring(0, [Math]::Min(200, $smOutput.Length)))"
        }
        elseif ($smOutput -match "expired token|Signature expired") {
            Write-SetupLog "SSO session stale — get-caller-identity succeeded but Secrets Manager rejected the token (auth error). Forcing re-login." -Level WARN
            Write-Warning "  [WARN] AWS session token is stale (can't access Secrets Manager). Re-authenticating..."
        } else {
            Write-SetupLog "Secrets Manager check failed (non-auth error: $($smOutput.Substring(0, [Math]::Min(200, $smOutput.Length)))) — treating as network issue, not stale session" -Level WARN
            Write-Warning "  [WARN] Secrets Manager check failed with non-auth error — proceeding with current session"
            return $SsoProfile
        }
    }

    if (-not $SkipCacheRepair -and ($IsWindows -or $env:OS -eq "Windows_NT")) {
        $AwsCliCachePath = Join-Path $AwsDir "cli"
        if (Test-Path $AwsCliCachePath) {
            $CacheResult = Invoke-AwsCommand { aws sts get-caller-identity --profile $SsoProfile --region $IdentityRegion 2>&1 }
            $CacheTest = $CacheResult.Output
            if ($CacheTest -match "WinError 183|Access is denied|Errno 13|Permission denied") {
                Write-SetupLog "AWS CLI cache corruption detected, attempting repair" -Level WARN
                try {
                    $null = cmd /c "takeown /F `"$AwsCliCachePath`" /R /D Y" 2>$null
                    $null = cmd /c "icacls `"$AwsCliCachePath`" /grant `"$($env:USERNAME):(F)`" /T" 2>$null
                    Remove-Item -Path $AwsCliCachePath -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not (Test-Path $AwsCliCachePath)) {
                        Write-SetupLog "AWS CLI cache corruption repaired"
                    }
                    else {
                        Write-SetupLog "AWS CLI cache repair failed — manual intervention needed" -Level ERROR
                        throw "AWS CLI cache directory is corrupted and could not be repaired. Run: Remove-Item -Path '$AwsCliCachePath' -Recurse -Force in an elevated terminal, then re-run."
                    }
                }
                catch {
                    Write-SetupLog "AWS CLI cache repair failed: $($_.Exception.Message)" -Level ERROR
                    throw "AWS CLI cache corruption repair failed. Run: Remove-Item -Path '$AwsCliCachePath' -Recurse -Force in an elevated terminal, then re-run."
                }
            }
        }
    }

    $SsoCachePath = Join-Path $AwsDir "sso" "cache"
    $CliCachePath = Join-Path $AwsDir "cli"

    # Detect headless or RDP session (no interactive desktop browser available)
    $isHeadless = -not [System.Environment]::UserInteractive -or
                  $null -eq [System.Environment]::GetEnvironmentVariable("DISPLAY") -or
                  $env:REMOTE_SESSION -eq "RDP" -or
                  (-not $NonInteractive -and $env:SSH_CONNECTION)

    if ($NonInteractive -or $isHeadless) {
        Write-SetupLog "SSO session expired and NonInteractive/headless mode — attempting device-code auth" -Level WARN
        Write-Warning "  [WARN] AWS session token is stale. Attempting device-code SSO login..."
        if (Test-Path $SsoCachePath) { Remove-Item -Path "$SsoCachePath\*" -Force -ErrorAction SilentlyContinue }
        if (Test-Path $CliCachePath) { Remove-Item -Path "$CliCachePath\*" -Recurse -Force -ErrorAction SilentlyContinue }
        $SsoResult = Invoke-AwsCommand { aws sso login --profile $SsoProfile --use-device-code 2>&1 }
        if (-not $SsoResult.Success) {
            $ssoOutput = $SsoResult.Output -join "`n"
            Write-SetupLog "AWS SSO login FAILED (device-code): $ssoOutput" -Level ERROR
            Write-Warning "`n  [FAIL] AWS SSO authentication failed. Run manually: aws sso login --profile $SsoProfile --use-device-code"
            throw "AWS SSO login via device code failed. Output: $ssoOutput"
        }
        Write-SetupLog "AWS SSO authenticated via device-code"
    } else {
        if (Test-Path $SsoCachePath) {
            Remove-Item -Path "$SsoCachePath\*" -Force -ErrorAction SilentlyContinue
            Write-SetupLog "Cleared stale AWS SSO cache before fresh login"
        }

        Write-SetupLog "Initiating AWS SSO login for profile: $SsoProfile"
        $SsoResult = Invoke-AwsCommand { aws sso login --profile $SsoProfile 2>&1 }
        $ssoOutput = $SsoResult.Output -join "`n"
        $needsRetry = $false

        if ($SsoResult.Success) {
            if ($ssoOutput -match "Successfully logged into Start URL:" -or $ssoOutput -match "already logged in") {
                Write-SetupLog "AWS SSO authenticated"
            } else {
                Write-SetupLog "AWS SSO login attempt 1 output did not confirm success — retrying" -Level WARN
                $needsRetry = $true
            }
        } else {
            Write-SetupLog "AWS SSO login attempt 1 FAILED: $ssoOutput" -Level WARN
            $needsRetry = $true
        }

        if ($needsRetry) {
            if (Test-Path $SsoCachePath) {
                Remove-Item -Path "$SsoCachePath\*" -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path $CliCachePath) {
                Remove-Item -Path "$CliCachePath\*" -Recurse -Force -ErrorAction SilentlyContinue
            }

            Write-Warning "  Retrying SSO login (attempt 2, plain)..."
            $SsoResult = Invoke-AwsCommand { aws sso login --profile $SsoProfile 2>&1 }
            if (-not $SsoResult.Success) {
                $ssoOutput = $SsoResult.Output -join "`n"
                Write-SetupLog "AWS SSO login attempt 2 FAILED: $ssoOutput" -Level WARN
                Write-Warning "  Retrying with --use-device-code (device authorization flow)..."

                if (Test-Path $SsoCachePath) {
                    Remove-Item -Path "$SsoCachePath\*" -Force -ErrorAction SilentlyContinue
                }
                if (Test-Path $CliCachePath) {
                    Remove-Item -Path "$CliCachePath\*" -Recurse -Force -ErrorAction SilentlyContinue
                }

                $SsoResult = Invoke-AwsCommand { aws sso login --profile $SsoProfile --use-device-code 2>&1 }
                if (-not $SsoResult.Success) {
                    Write-SetupLog "AWS SSO login FAILED (all attempts): $($SsoResult.Output -join ' ')" -Level ERROR
                    Write-Warning "`n  [FAIL] AWS SSO authentication failed."
                    Write-Warning "  Try running manually:"
                    Write-Verbose "    aws sso login --profile $SsoProfile"
                    Write-Warning "  Or with device code:"
                    Write-Verbose "    aws sso login --profile $SsoProfile --use-device-code"
                    throw "AWS SSO login failed after retry. Output: $($SsoResult.Output -join ' ')"
                }
            }
            Write-SetupLog "AWS SSO authenticated"
        }
    }

    # Clear CLI cache before verification — stale cache files from prior runs
    # with different permissions cause Errno 13 / Permission denied on Windows.
    $CliCachePath = Join-Path $AwsDir "cli"
    if (Test-Path $CliCachePath) {
        Remove-Item -Path "$CliCachePath\*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    $VerifyResult = Invoke-AwsCommand { aws sts get-caller-identity --profile $SsoProfile --region $IdentityRegion 2>&1 }
    if (-not $VerifyResult.Success) {
        Write-SetupLog "SSO session verification FAILED after login" -Level ERROR
        throw "AWS SSO session verification failed after login. Output: $($VerifyResult.Output)"
    }
    Write-SetupLog "SSO session verified for $SsoProfile"

    return $SsoProfile
}
