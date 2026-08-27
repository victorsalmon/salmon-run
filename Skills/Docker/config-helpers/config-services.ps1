function Invoke-BrowserlessPhase {
    param([switch]$NonInteractive, [switch]$Force)
    if (-not (Should-ConfigureFeature -FeatureName "browserless")) { return }
    Write-Host "`n[PHASE 20] Browserless Configuration..." -ForegroundColor Cyan
    $project = ($Config.Project ?? "").Trim()
    $awsProfile = $global:AwsSsoProfile ?? $env:AWS_SSO_PROFILE ?? "default"
    $SecretsRegion = $env:AWS_SECRETS_REGION ?? (Get-DefaultRegion -RegionType AWS_SECRETS_REGION)

    $currentToken = Get-SecretFromAws -KeyName "BROWSERLESS_API_KEY" -SsoProfile $awsProfile -Region $SecretsRegion -ErrorAction SilentlyContinue

    if ($currentToken -and -not $Force) {
        Write-Host "  [OK] Browserless token already configured." -ForegroundColor Green
        Set-Item -Path "Env:\BROWSERLESS_API_KEY" -Value $currentToken
        Write-SetupLog "Browserless token already exists in AWS SM"
    } else {
        if ($NonInteractive) {
            $newToken = "bl-$(crypto random 24 -Encoding Hex)"
            Write-Host "  [GENERATED] Browserless token (non-interactive mode)." -ForegroundColor Yellow
            Write-SetupLog "Browserless token generated (non-interactive)"
        } else {
            $existingVal = if ($currentToken) { " (current: ...$($currentToken.Substring([math]::Max(0, $currentToken.Length - 8))))" } else { "" }
            Write-Host "  Browserless requires an API token for agent authentication." -ForegroundColor Gray
            $choice = Read-Host "  Generate a new token? [Y/n]$existingVal"
            if ($choice -match '^[Nn]') {
                Write-Host "  [SKIP] Browserless token unchanged." -ForegroundColor Gray
                Write-SetupLog "Browserless config skipped by user"
                if ($currentToken) { Set-Item -Path "Env:\BROWSERLESS_API_KEY" -Value $currentToken }
                return
            }
            $newToken = "bl-$(crypto random 24 -Encoding Hex)"
        }

        Set-Item -Path "Env:\BROWSERLESS_API_KEY" -Value $newToken
        Write-Host "  Browserless TOKEN: ...$($newToken.Substring($newToken.Length - 4))" -ForegroundColor Gray
        Write-Host "  [INFO] Token set for this session. It is automatically bundled into Docker secrets on fleet deploy." -ForegroundColor Gray
        Write-Host "  Agents on the overlay network must include this token in Browserless API calls." -ForegroundColor Gray
    }
}

function Invoke-DocusignPhase {
    param([switch]$NonInteractive, [switch]$Force)
    if (-not (Should-ConfigureFeature -FeatureName "docusign")) { return }
    Write-Host "`n[PHASE 21] DocuSign SMTP Configuration..." -ForegroundColor Cyan
    $project = ($Config.Project ?? "").Trim()
    $awsProfile = $global:AwsSsoProfile ?? $env:AWS_SSO_PROFILE ?? "default"
    $SecretsRegion = $env:AWS_SECRETS_REGION ?? (Get-DefaultRegion -RegionType AWS_SECRETS_REGION)

    $existingHost = Get-SecretFromAws -KeyName "DOCUSIGN_SMTP_HOST" -SsoProfile $awsProfile -Region $SecretsRegion -ErrorAction SilentlyContinue

    if ($existingHost -and -not $Force) {
        Write-Host "  [OK] DocuSign SMTP already configured." -ForegroundColor Green
        $env:DOCUSIGN_SMTP_HOST = $existingHost
        $env:DOCUSIGN_SMTP_PORT = Get-SecretFromAws -KeyName "DOCUSIGN_SMTP_PORT" -SsoProfile $awsProfile -Region $SecretsRegion -ErrorAction SilentlyContinue
        $env:DOCUSIGN_SMTP_USER = Get-SecretFromAws -KeyName "DOCUSIGN_SMTP_USER" -SsoProfile $awsProfile -Region $SecretsRegion -ErrorAction SilentlyContinue
        $env:DOCUSIGN_SMTP_FROM = Get-SecretFromAws -KeyName "DOCUSIGN_SMTP_FROM" -SsoProfile $awsProfile -Region $SecretsRegion -ErrorAction SilentlyContinue
        Write-SetupLog "DocuSign SMTP config already exists in AWS SM"
        return
    }

    if ($NonInteractive) {
        Write-Host "  [SKIP] NonInteractive mode — skip SMTP config." -ForegroundColor Gray
        Write-SetupLog "DocuSign SMTP config skipped (NonInteractive)"
        return
    }

    Write-Host "  DocuSign sends signing links via email. Configure SMTP to enable this." -ForegroundColor Gray
    $doSmtp = Read-Host "  Configure SMTP now? [y/N] "
    if ($doSmtp -notmatch '^[Yy]') {
        Write-Host "  [SKIP] SMTP config skipped. Signing links will appear in logs only." -ForegroundColor Gray
        Write-SetupLog "DocuSign SMTP config skipped by user"
        return
    }

    $smtpHost = Read-Host "  SMTP Host (e.g. smtp.sendgrid.net)"
    $smtpPort = Read-Host "  SMTP Port [587]"
    if (-not $smtpPort) { $smtpPort = "587" }
    $smtpUser = Read-Host "  SMTP Username"
    $smtpPass = Read-Host "  SMTP Password" -AsSecureString
    $smtpFrom = Read-Host "  From email (e.g. noreply@intersite.io)"

    $Bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($smtpPass)
    $smtpPassPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)

    $env:DOCUSIGN_SMTP_HOST = $smtpHost
    $env:DOCUSIGN_SMTP_PORT = $smtpPort
    $env:DOCUSIGN_SMTP_USER = $smtpUser
    $env:DOCUSIGN_SMTP_PASS = $smtpPassPlain
    $env:DOCUSIGN_SMTP_FROM = $smtpFrom
    Write-Host "  [OK] SMTP configured for DocuSign." -ForegroundColor Green
    Write-SetupLog "DocuSign SMTP config completed"
}

function Invoke-WebMcpPhase {
    param([switch]$NonInteractive, [switch]$Force)
    Write-Host "`n[PHASE 22] Web MCP — RETIRED (2026-08-22). Skipping." -ForegroundColor Gray
    Write-SetupLog "Phase 22 (web-mcp) retired — skipped"
}
