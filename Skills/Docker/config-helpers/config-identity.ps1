function Invoke-AwsSsoPhase {
    Write-Host "`n[PHASE] AwsSso..." -ForegroundColor Cyan
    Write-SetupLog "Phase starting: AwsSso"
    try {
        Write-SetupLog "Phase 17: AWS SSO"
        $SecretsRegion = $env:AWS_SECRETS_REGION ?? (Get-DefaultRegion -RegionType AWS_SECRETS_REGION)

        $detectedProfile = $env:AWS_SSO_PROFILE
        if (-not $detectedProfile) {
            $awsConfigPath = Join-Path (Get-HomeDir) ".aws/config"
            if (Test-Path $awsConfigPath) {
                $profiles = @()
                Get-Content $awsConfigPath | ForEach-Object {
                    if ($_ -match '^\[profile\s+(.+)\]$') { $profiles += $matches[1] }
                    elseif ($_ -match '^\[default\]$') { $profiles += "default" }
                }
                $profiles = @($profiles | Where-Object { $_ -ne "sso-session" })
                if ($profiles.Count -eq 1) { $detectedProfile = $profiles[0] }
            }
        }
        if (-not $detectedProfile) { $detectedProfile = "default" }

        $idResult = Invoke-NativeCommand { aws sts get-caller-identity --profile $detectedProfile --output json 2>&1 }
        if ($idResult.Success) {
            $global:AwsSsoProfile = $detectedProfile
            Write-Host "  [OK] SSO session already active for profile '$detectedProfile'" -ForegroundColor Green
        } elseif ($SkipAWSLogin) {
            Write-Host "  [AUTH] SSO session expired — SkipAWSLogin set, no auth attempted. AWS operations will fail unless cached credentials are valid." -ForegroundColor Yellow
            Write-SetupLog "AWS STS pre-check: no active session for '$detectedProfile' — SkipAWSLogin set, skipping auth" -Level WARN
            $global:AwsSsoProfile = $detectedProfile
        } else {
            Write-Host "  [AUTH] SSO session expired — re-authenticating..." -ForegroundColor Yellow
            Write-SetupLog "AWS STS pre-check: no active session for '$detectedProfile'" -Level WARN
            $global:AwsSsoProfile = Initialize-AwsSsoSession -SsoProfile $detectedProfile -SecretsRegion $SecretsRegion -NonInteractive:$NonInteractive
        }

        Write-SetupLog "AWS SSO profile: $global:AwsSsoProfile"
        Write-SetupLog "Phase complete: AwsSso"
    }
    catch {
        $msg = $_.Exception.Message
        throw "Fatal error in phase [AwsSso]: $msg"
    }
}

function Invoke-OwnerConfigPhase {
    param([switch]$NonInteractive, [switch]$Force)
    if (-not $NonInteractive) {
        Write-Host "`n[PHASE 18] Owner Configuration..." -ForegroundColor Cyan
        $existing = Get-OwnerPlaceholders
        $hasExisting = $existing.Count -gt 0
        $needsConfig = if ($hasExisting -and -not $Force) { $false } else { $true }

        if ($hasExisting -and -not $Force) {
            $reconfig = Read-Host "  Owner already configured. Reconfigure? [y/N/C] "
            if ($reconfig -match '^[Cc]') {
                Write-Host "  Cancel requested. Owner config unchanged." -ForegroundColor Yellow
                Write-SetupLog "Owner config cancelled by user"
                return
            }
            $needsConfig = $reconfig -match '^[Yy]'
        }
        elseif ($hasExisting -and $Force) {
            $needsConfig = $true
            Write-Host "  Force mode — reconfiguring owner..." -ForegroundColor Gray
        }

        if ($needsConfig) {
            Set-OwnerPlaceholders
        } else {
            Write-Host "  [SKIP] Owner config unchanged." -ForegroundColor Gray
        }
    }
    Set-SetupCheckpoint -Name "OwnerConfig"
}
