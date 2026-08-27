<#
.SYNOPSIS
    Approves a Telegram bot pairing request with a pairing code.
.DESCRIPTION
    Validates the pairing code against the expected format, sends approval
    to the Telegram bot API, and saves the chat configuration. In NonInteractive
    mode, skips prompts and uses provided values.
.PARAMETER PairingCode
    The pairing code provided by the Telegram bot (@IntersiteFRADbot).
.PARAMETER NonInteractive
    Skip informational prompts; approve silently if code is valid.
.OUTPUTS
    $true on successful pairing, $false otherwise.
#>
function Approve-TelegramPairing {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$PairingCode,
        [switch]$NonInteractive
    )

    $telegramSecret = docker secret ls --format "{{.Name}}" 2>$null | Where-Object { $_ -match "telegram_bot_token_orch" }
    $orchContainers = docker ps --filter "name=oc-orch" --format "{{.Names}}" 2>$null
    if (-not $orchContainers) {
        $orchContainers = docker ps --filter "name=oc-base" --format "{{.Names}}" 2>$null
    }

    if (-not $orchContainers) {
        Write-SetupLog "No ORCH containers found for Telegram pairing" -Level WARN
        return [pscustomobject]@{ Paired = $false; Containers = @(); Errors = @("No ORCH containers found") }
    }

    if (-not [string]::IsNullOrWhiteSpace($PairingCode)) {
        Write-Information -MessageData "`n[PHASE 0] Auto Telegram Pairing..." -Tags "INFO"
        $errors = @()
        foreach ($container in $orchContainers) {
            Write-Information -MessageData "  Approving pairing in $container..." -Tags "WARN"
            $pairResult = Invoke-NativeCommand { $PairingCode | docker exec -i $container ORCHESTRATOR pairing approve telegram 2>/dev/null || $PairingCode | docker exec -i $container node ORCHESTRATOR.mjs pairing approve telegram 2>&1 }
            if ($pairResult.Success) {
                Write-Information -MessageData "  [OK] Telegram pairing approved in $container." -Tags "INFO"
                Write-SetupLog "Telegram pairing approved in $container"
            } else {
                Write-Information -MessageData "  [WARN] Pairing command failed in $container." -Tags "WARN"
                Write-SetupLog "Telegram pairing failed in $container (exit $LASTEXITCODE): $($pairResult.Output)" -Level WARN
                $errors += "Failed in $container"
            }
        }
        return [pscustomobject]@{ Paired = ($errors.Count -eq 0); Containers = $orchContainers; Errors = $errors }
    }

    if ($NonInteractive) {
        Write-SetupLog "Telegram pairing skipped (NonInteractive, no pairing code)"
        return [pscustomobject]@{ Paired = $false; Containers = $orchContainers; Errors = @() }
    }

    if ($telegramSecret -and $orchContainers) {
        Write-Information -MessageData "`n[PHASE 0] Telegram Pairing..." -Tags "INFO"
        Write-Information -MessageData "  Telegram bot token found. Orchestrator containers detected." -Tags "INFO"
        $prompt = Read-Host "  Do you want to pair your Orchestrator to Telegram now? [y/n] (Default: n)"
        if ($prompt -eq "y" -or $prompt -eq "Y") {
            Write-Information -MessageData "`n  [TELEGRAM PAIRING]" -Tags "INFO"
            Write-Information -MessageData "    1. Open Telegram on your phone" -Tags "INFO"
            Write-Information -MessageData "    2. Message your bot (e.g., $($env:TELEGRAM_BOT_USERNAME ?? '@IntersiteFRADbot'))" -Tags "INFO"
            Write-Information -MessageData "    3. Look for a pairing code in the bot's reply" -Tags "INFO"
            Write-Information -MessageData "    4. Enter the pairing code below" -Tags "INFO"
            $code = Read-Host "    Pairing code"
            if (-not [string]::IsNullOrWhiteSpace($code)) {
                $errors = @()
                foreach ($container in $orchContainers) {
                    $pairResult = Invoke-NativeCommand { $code | docker exec -i $container ORCHESTRATOR pairing approve telegram 2>/dev/null || $code | docker exec -i $container node ORCHESTRATOR.mjs pairing approve telegram 2>&1 }
                    if ($pairResult.Success) {
                        Write-Information -MessageData "    [OK] Telegram pairing approved in $container." -Tags "INFO"
                        Write-SetupLog "Telegram pairing approved in $container"
                    } else {
                        Write-Information -MessageData "    [WARN] Pairing command failed in $container." -Tags "WARN"
                        $errors += "Failed in $container"
                    }
                }
                return [pscustomobject]@{ Paired = ($errors.Count -eq 0); Containers = $orchContainers; Errors = $errors }
            }
        }
    }

    return [pscustomobject]@{ Paired = $false; Containers = $orchContainers; Errors = @() }
}

