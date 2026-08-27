# Boundary: No credentials — Telegram pairing, approval, config
@{
    RootModule = 'SalmonRun.Telegram.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'b54f7246-ba42-4e61-91b6-564cd8b1feb2'
    Author               = 'Interclaw'
    Description          = 'Telegram bot pairing and security for Interclaw fleet management'
    PowerShellVersion    = '7.0'
    # Uses: Diagnostics (Write-SetupLog, Get-ReportsDir)
    RequiredModules      = @('SalmonRun.Core', 'SalmonRun.Process')
    FunctionsToExport    = @(
        'Approve-TelegramPairing',
        'Invoke-TelegramPollingWithBackoff',
        'Send-TelegramMessage',
        'Receive-TelegramMessages'
    )
    PrivateData = @{
        PSData = @{ }
    }
}
