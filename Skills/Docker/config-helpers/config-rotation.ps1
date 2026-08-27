function Invoke-CodingKeyCheckPhase {
    if (-not (Should-ConfigureFeature -FeatureName "opencode")) { return }
    Write-Host "`n[PHASE 23] Coding Key ON-Flag State Check..." -ForegroundColor Cyan

    $awsProfile = $global:AwsSsoProfile ?? $env:AWS_SSO_PROFILE ?? "default"
    $SecretsRegion = $env:AWS_SECRETS_REGION ?? (Get-DefaultRegion -RegionType AWS_SECRETS_REGION)

    $smResult = Invoke-NativeCommand { aws secretsmanager get-secret-value --secret-id (Get-AwsSecretId -Purpose Provisioning) --profile $awsProfile --region $SecretsRegion --query "SecretString" --output text 2>&1 }
    if (-not $smResult.Success) {
        Write-Host "  [SKIP] Could not read Provisioning secret from AWS SM." -ForegroundColor Yellow
        Write-SetupLog "ON-flag check: AWS SM read failed" -Level WARN
        return
    }

    $provisioning = try { $smResult.Output | ConvertFrom-Json } catch { $null }
    if (-not $provisioning) {
        Write-Host "  [SKIP] Could not parse Provisioning secret." -ForegroundColor Yellow
        return
    }

    $currentOn = @{}
    $resolvedCount = 0
    for ($i = 1; $i -le 5; $i++) {
        $key = "OPENCODE_GO${i}_ON"
        if ($null -ne $provisioning.$key) {
            $currentOn[$key] = $provisioning.$key
            $resolvedCount++
        }
    }

    if ($resolvedCount -eq 0) {
        Write-Host "  [SKIP] No ON flags found in Provisioning secret." -ForegroundColor Yellow
        return
    }

    Write-Host "`n  Coding key status:" -ForegroundColor Gray
    $currentOn.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $icon = if ($_.Value -eq "true") { "●" } else { "○" }
        $color = if ($_.Value -eq "true") { "Green" } else { "DarkYellow" }
        Write-Host "    $icon $($_.Name) = $($_.Value)" -ForegroundColor $color
    }

    if (-not $NonInteractive) {
        $regenerate = Read-Host "`n  Regenerate coding secrets bundle with current ON flags? [Y/n] "
        if ($regenerate -match '^[Nn]') {
            Write-Host "  [SKIP] Bundle regeneration skipped." -ForegroundColor Gray
            Write-SetupLog "ON-flag bundle regeneration declined by user"
            return
        }
    }

    Write-Host "  Regenerating coding secrets bundle..." -ForegroundColor Gray
    Import-InterclawModule Secrets
    $previousRotate = $env:ROTATE_PREEXISTING_KEYS
    $env:ROTATE_PREEXISTING_KEYS = "true"
    try {
        Publish-CodingKeySecrets -SsoProfile $awsProfile
        Write-Host "  [OK] Coding secrets bundle regenerated with current ON flags." -ForegroundColor Green
        Write-SetupLog "ON-flag check: coding bundle regenerated"
    } catch {
        Write-Host "  [WARN] Bundle regeneration failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-SetupLog "ON-flag check: bundle regeneration failed: $_" -Level WARN
    } finally {
        if ($previousRotate) { $env:ROTATE_PREEXISTING_KEYS = $previousRotate }
        else { Remove-Item Env:\ROTATE_PREEXISTING_KEYS -ErrorAction SilentlyContinue }
    }
}

function Invoke-SecretRotationPhase {
    Write-Host "`n[PHASE 24] Secret Rotation Check..." -ForegroundColor Cyan

    $awsProfile = $global:AwsSsoProfile ?? $env:AWS_SSO_PROFILE ?? "default"
    $ssoProfile = $awsProfile

    $installJson = Read-InstallJson
    $rotatableKeys = @{}
    $totalKeys = 0

    foreach ($featureName in $installJson.features.PSObject.Properties.Name) {
        $feature = $installJson.features.$featureName
        if ($feature.rotate -and $feature.rotate.Count -gt 0 -and $feature.install -ne $false) {
            $rotatableKeys[$featureName] = @{
                Keys = $feature.rotate
                Install = $feature.install
            }
            $totalKeys += $feature.rotate.Count
        }
    }

    if ($totalKeys -eq 0) {
        Write-Host "  [SKIP] No rotatable keys configured in install.json." -ForegroundColor Gray
        Write-SetupLog "Rotation check: no rotate arrays found in install.json"
        return
    }

    Write-Host "`n  Rotatable keys found:" -ForegroundColor Gray
    foreach ($fn in $rotatableKeys.Keys | Sort-Object) {
        $info = $rotatableKeys[$fn]
        Write-Host "    $fn ($($info.Keys -join ', '))" -ForegroundColor Gray
    }

    $autoRotate = $env:ROTATE_PREEXISTING_KEYS -eq "true"
    if (-not $autoRotate -and -not $NonInteractive) {
        $doRotate = Read-Host "`n  Rotate secrets for all active containers? (reads fresh values from AWS SM) [y/N] "
        if ($doRotate -notmatch '^[Yy]') {
            Write-Host "  [SKIP] Secret rotation skipped." -ForegroundColor Gray
            Write-SetupLog "Secret rotation declined by user"
            return
        }
    } elseif (-not $autoRotate) {
        Write-Host "  [SKIP] NonInteractive mode and ROTATE_PREEXISTING_KEYS not set." -ForegroundColor Gray
        Write-SetupLog "Secret rotation skipped (NonInteractive, no flag)"
        return
    }

    Import-InterclawModule Secrets
    Import-InterclawModule Deploy

    $previousRotate = $env:ROTATE_PREEXISTING_KEYS
    $env:ROTATE_PREEXISTING_KEYS = "true"

    $rotated = @()
    $skipped = @()
    $errors = @()

    try {
        foreach ($fn in ($rotatableKeys.Keys | Sort-Object)) {
            $info = $rotatableKeys[$fn]
            Write-Host "  [ROTATING] $fn ..." -ForegroundColor Cyan

            switch ($fn) {
                "opencode" {
                    try {
                        Publish-CodingKeySecrets -SsoProfile $ssoProfile
                        $rotated += "coding_secrets_bundle"
                        Write-Host "    [OK] Coding keys bundle regenerated." -ForegroundColor Green
                        Write-SetupLog "Rotation: coding_secrets_bundle regenerated"
                    } catch {
                        $errors += "coding_secrets_bundle: $_"
                        Write-Host "    [WARN] Coding keys rotation failed: $_" -ForegroundColor Yellow
                    }
                }
                "is-fleet" {
                    $rotated += "is-fleet secrets (no-op — github token in bundle)"
                    Write-Host "    [OK] Fleet secrets (no-op, github token in bundle)." -ForegroundColor Green
                    Write-SetupLog "Rotation: is-fleet secrets (no-op)"
                }
                "web-mcp" {
                    $skipped += "web_mcp_secrets_bundle"
                    Write-Host "    [SKIP] Web MCP retired — secrets no longer rotated." -ForegroundColor Gray
                    Write-SetupLog "Rotation: web-mcp skipped (retired 2026-08-22)"
                }
                "api-proxy" {
                    Write-Host "    [SKIP] Proxy bundle rotation requires redeploy (Publish-FleetStack)." -ForegroundColor Gray
                    $skipped += "proxy_bundle"
                    Write-SetupLog "Rotation: api-proxy skipped (requires redeploy)"
                }
                default {
                    Write-Host "    [SKIP] No automated rotation for feature '$fn'." -ForegroundColor Gray
                    $skipped += $fn
                    Write-SetupLog "Rotation: $fn skipped (no automation)"
                }
            }
        }
    } finally {
        if ($previousRotate) { $env:ROTATE_PREEXISTING_KEYS = $previousRotate }
        else { Remove-Item Env:\ROTATE_PREEXISTING_KEYS -ErrorAction SilentlyContinue }
    }

    Write-Host "`n  --- Rotation Summary ---" -ForegroundColor Cyan
    if ($rotated.Count -gt 0) { Write-Host "  Rotated: $($rotated -join ', ')" -ForegroundColor Green }
    if ($skipped.Count -gt 0) { Write-Host "  Skipped: $($skipped -join ', ')" -ForegroundColor DarkYellow }
    if ($errors.Count -gt 0) {
        Write-Host "  Errors:" -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "    - $e" -ForegroundColor Red }
    }
    Write-SetupLog "Rotation complete: $($rotated.Count) rotated, $($skipped.Count) skipped, $($errors.Count) errors"
}
