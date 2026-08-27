function Invoke-TelegramPairingPhase {
    param(
        [string]$TelegramPairingCode,
        [switch]$NonInteractive,
        [switch]$Force,
        [string]$ScriptName
    )
    if (-not (Should-ConfigureFeature -FeatureName "gateway")) { return }
    if ($NonInteractive) {
        Write-Host "  [SKIP] NonInteractive mode — Telegram pairing deferred." -ForegroundColor Gray
        Write-SetupLog "Telegram pairing skipped (NonInteractive — run $ScriptName manually to pair)"
        return
    }

    Import-InterclawModule Telegram
    $telegramResult = docker secret ls --format "{{.Name}}" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "docker secret ls failed: $telegramResult" }
    $telegramSecret = $telegramResult | Where-Object { $_ -match "telegram_bot_token_orch" }
    $containerResult = docker ps --filter "name=oc-orch" --format "{{.Names}}" 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "docker ps failed: $containerResult" }
    $orchContainers = $containerResult

    if ($telegramSecret -and $orchContainers -and -not $Force) {
        $rePair = Read-Host "  Do you want to pair your ORCH agent to Telegram again? [y/N]"
        if ($rePair -notmatch '^[Yy]') {
            Write-SetupLog "Telegram re-pairing declined by user"
            Write-Host "  [SKIP] Telegram re-pairing skipped." -ForegroundColor Gray
            return
        }
    }

    $telegramResult = Approve-TelegramPairing -PairingCode $TelegramPairingCode -NonInteractive:$NonInteractive
    if ($telegramResult -and -not $telegramResult.Paired) {
        $errors = $telegramResult.Errors -join '; '
        if ($errors -match 'No ORCH containers found') {
            Write-SetupLog "Telegram pairing requires a deployed stack — run deploy.ps1 first" -Level INFO
            Write-Host "  [INFO] Telegram pairing requires ORCH containers. Deploy the stack first, then re-run config.ps1." -ForegroundColor DarkYellow
        } else {
            Write-SetupLog -Message "Telegram pairing failed or was not completed. You can retry later." -Level WARN
            if ($errors) {
                Write-SetupLog "Telegram pairing did not succeed: $errors" -Level WARN
            }
        }
    }
}

function Invoke-MobileAppPairingPhase {
    param(
        [switch]$NonInteractive,
        [string]$ScriptName
    )
    Write-Host "`n[PHASE 16b] ORCHESTRATOR Mobile App..." -ForegroundColor Cyan
    if ($NonInteractive) {
        Write-Host "  [SKIP] NonInteractive mode." -ForegroundColor Gray
        Write-SetupLog "Mobile app pairing skipped (NonInteractive)"
        return
    }

    $doMobile = Read-Host "  Pair the ORCHESTRATOR Android/iOS app with your gateway? [y/N] "
    if ($doMobile -match '^[Yy]') {
        $orchResult = Invoke-NativeCommand { docker ps --filter "name=oc-orch" --format "{{.Names}}" 2>$null }
        $orchOutput = if ($orchResult) { $orchResult.Output } else { $null }
        $orchContainer = if ($orchOutput -and $orchOutput.Trim()) { $orchOutput.Trim() } else { $null }
        if (-not $orchContainer) {
            Write-Host "  [WARN] No ORCH container running. Deploy the stack first." -ForegroundColor Yellow
            Write-SetupLog "Mobile app pairing: no ORCH container found" -Level WARN
            return
        }

        Write-Host "`n  [MOBILE PAIRING]" -ForegroundColor Cyan
        Write-Host "  1. Install the ORCHESTRATOR app on your phone" -ForegroundColor Gray

        $pairMethod = Read-Host "  2. Choose method — [Q]R code or [T]ext setup code? [Q/T] "
        try {
            if ($pairMethod -match '^[Tt]') {
                $codeResult = Invoke-NativeCommand { docker exec $orchContainer ORCHESTRATOR qr --setup-code-only }
                if ($codeResult.Success) {
                    Write-Host "  Setup code: $($codeResult.Output.Trim())"
                    Write-Host "`n  [OK] Enter this code in your app's Advanced Setup." -ForegroundColor Green
                    Write-SetupLog "Mobile app pairing setup code displayed"
                } else {
                    Write-Host "  [WARN] Could not generate setup code." -ForegroundColor Yellow
                    Write-SetupLog "Mobile app pairing failed: $($codeResult.Output)" -Level WARN
                }
            } else {
                $qrResult = Invoke-NativeCommand { docker exec $orchContainer ORCHESTRATOR qr }
                if ($qrResult.Success) {
                    Write-Host "$($qrResult.Output)"
                    Write-Host "`n  [OK] Scan the QR code or enter the setup code in your app." -ForegroundColor Green
                    Write-SetupLog "Mobile app pairing QR displayed"
                } else {
                    Write-Host "  [WARN] Could not generate QR. Trying setup code only..." -ForegroundColor Yellow
                    $codeResult = Invoke-NativeCommand { docker exec $orchContainer ORCHESTRATOR qr --setup-code-only }
                    if ($codeResult.Success) {
                        Write-Host "  Setup code: $($codeResult.Output.Trim())"
                        Write-Host "`n  [OK] Enter this code in your app's Advanced Setup." -ForegroundColor Green
                        Write-SetupLog "Mobile app pairing setup code displayed"
                    } else {
                        Write-Host "  [WARN] Could not generate pairing code." -ForegroundColor Yellow
                        Write-SetupLog "Mobile app pairing failed: $($codeResult.Output)" -Level WARN
                    }
                }
            }
        } catch {
            Write-Host "  [WARN] Mobile pairing command failed: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-SetupLog "Mobile app pairing exception: $($_.Exception.Message)" -Level WARN
        }
    } else {
        Write-Host "  [SKIP] Mobile app pairing skipped." -ForegroundColor Gray
        Write-SetupLog "Mobile app pairing skipped by user"
    }
}
