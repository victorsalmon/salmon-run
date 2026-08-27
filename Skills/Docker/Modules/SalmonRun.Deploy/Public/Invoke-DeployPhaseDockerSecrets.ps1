<#
.SYNOPSIS
    Publishes secrets from environment variables to Docker Swarm.
.DESCRIPTION
    Snapshots required env vars, persists gateway token and server password
    with DPAPI encryption, then publishes coding keys, gateway password,
    proxy API tokens, and web MCP secrets to Swarm.
#>
function Invoke-DeployPhaseDockerSecrets {
    param(
        [string]$SsoProfile,
        [string]$ProjectCode,
        [string]$GatewayToken,
        [ref]$InstallOpencodeRef,
        [ref]$HasCodingKeysRef,
        [int]$AgentNumber,
        [string]$InstallFleet,
        [string]$InstallTailscale,
        [string]$InstallBrowserless
    )

    Write-Information -MessageData "`n[DOCKER SECRETS] Publishing secrets to Docker Swarm..." -Tags "INFO"

    $persistedDir = "$env:USERPROFILE\.ORCHESTRATOR"
    $persistedPasswordFile = Join-Path $persistedDir ".last-opencode-password"
    $persistedTokenFile = Join-Path $persistedDir ".last-gateway-token"
    if (-not $env:OPENCODE_SERVER_PASSWORD) {
        if (Test-Path $persistedPasswordFile) {
            try {
                $encrypted = [System.IO.File]::ReadAllBytes($persistedPasswordFile)
                $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                $env:OPENCODE_SERVER_PASSWORD = [System.Text.Encoding]::UTF8.GetString($decrypted)
            } catch {
                $env:OPENCODE_SERVER_PASSWORD = Get-Content $persistedPasswordFile -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
                if ($env:OPENCODE_SERVER_PASSWORD) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($env:OPENCODE_SERVER_PASSWORD)
                    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                    [System.IO.File]::WriteAllBytes($persistedPasswordFile, $encrypted)
                    Write-SetupLog "Migrated $persistedPasswordFile to DPAPI-encrypted format" -Level INFO
                }
            }
            Write-SetupLog "Reusing persisted OPENCODE_SERVER_PASSWORD from $persistedPasswordFile" -Level INFO
        }
        if (-not $env:OPENCODE_SERVER_PASSWORD) {
            $env:OPENCODE_SERVER_PASSWORD = New-CryptographicToken -ByteCount 32
            Write-SetupLog "Auto-generated OPENCODE_SERVER_PASSWORD (cryptographic)" -Level INFO
        }
    }

    if (-not $env:INTERCLAW_GATEWAY_TOKEN) {
        if ($GatewayToken) {
            $env:INTERCLAW_GATEWAY_TOKEN = $GatewayToken
            Write-SetupLog "Using gateway token from Phase 9a (script-scoped cache)" -Level INFO
        } elseif (Test-Path $persistedTokenFile) {
            try {
                $encrypted = [System.IO.File]::ReadAllBytes($persistedTokenFile)
                $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect($encrypted, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                $env:INTERCLAW_GATEWAY_TOKEN = [System.Text.Encoding]::UTF8.GetString($decrypted)
            } catch {
                $env:INTERCLAW_GATEWAY_TOKEN = Get-Content $persistedTokenFile -Raw -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() }
                if ($env:INTERCLAW_GATEWAY_TOKEN) {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($env:INTERCLAW_GATEWAY_TOKEN)
                    $encrypted = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                    [System.IO.File]::WriteAllBytes($persistedTokenFile, $encrypted)
                    Write-SetupLog "Migrated $persistedTokenFile to DPAPI-encrypted format" -Level INFO
                }
            }
            Write-SetupLog "Reusing persisted INTERCLAW_GATEWAY_TOKEN from $persistedTokenFile" -Level INFO
        } else {
            $env:INTERCLAW_GATEWAY_TOKEN = New-CryptographicToken -ByteCount 48
            Write-SetupLog "Auto-generated INTERCLAW_GATEWAY_TOKEN (cryptographic)" -Level INFO
        }
    }

    $null = New-Item -ItemType Directory -Path $persistedDir -Force
    $passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($env:OPENCODE_SERVER_PASSWORD)
    $encryptedPassword = [System.Security.Cryptography.ProtectedData]::Protect($passwordBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($persistedPasswordFile, $encryptedPassword)
    $tokenBytes = [System.Text.Encoding]::UTF8.GetBytes($env:INTERCLAW_GATEWAY_TOKEN)
    $encryptedToken = [System.Security.Cryptography.ProtectedData]::Protect($tokenBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes($persistedTokenFile, $encryptedToken)

    $SecretEnv = @{}
    $RequiredEnvVars = @(
        'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN',
        'OPENROUTER_API_KEY', 'OPENROUTER_CODE_KEY', 'OPENCODE_GO1_KEY', 'OPENCODE_GO2_KEY',
        'OPENCODE_GO3_KEY', 'OPENCODE_GO4_KEY',
        'OPENCODE_GO1_EMAIL', 'OPENCODE_GO2_EMAIL',
        'OPENCODE_GO3_EMAIL', 'OPENCODE_GO4_EMAIL',
        'OPENCODE_GO5_KEY', 'OPENCODE_GO5_EMAIL',
        'OPENCODE_GO1_ON', 'OPENCODE_GO2_ON', 'OPENCODE_GO3_ON', 'OPENCODE_GO4_ON', 'OPENCODE_GO5_ON',
        'TELEGRAM_BOT_TOKEN_ORCH', 'TELEGRAM_CHAT_ID',
        'GATEWAY_TOKEN_BASE',
        'GITHUB_TOKEN_READALL', 'GITHUB_TOKEN_PUSHSELECT', 'FLEET_GITHUB_TOKEN_READALL',
        'ATTIO_READ_KEY', 'ATTIO_WRITE_KEY', 'ATTIO_ARCHIVE_KEY'
    )
    foreach ($VarName in $RequiredEnvVars) {
        $Value = Get-Item -LiteralPath "Env:\$VarName" -ErrorAction SilentlyContinue
        if ($Value) {
            $SecretEnv[$VarName] = $Value.Value
        }
    }

    Write-SetupLog "Snapshotted $($SecretEnv.Count) env vars for secret publishing" -Level DEBUG

    $null = Publish-CodingKeySecrets -SecretEnv $SecretEnv -SsoProfile $SsoProfile
    $null = Publish-GatewayPasswordSecret -SecretEnv $SecretEnv -ProjectCode $ProjectCode -SsoProfile $SsoProfile
    $null = Import-ProxyApiFromAws -ProjectCode $ProjectCode -SsoProfile $SsoProfile
    $null = Publish-WebMcpSecrets -SsoProfile $SsoProfile

    if (-not $HasCodingKeysRef.Value) {
        Write-SetupLog -Message "No coding keys available (detected at pre-flight) - disabling mcp_opencode containers." -Level WARN
        Set-Item -Path "Env:\INSTALL_OPENCODE" -Value "false"
        $InstallOpencodeRef.Value = "false"
    } else {
        Measure-DockerResources -AgentCount $AgentNumber -InstallFleet $InstallFleet -InstallTailscale $InstallTailscale
    }
}
