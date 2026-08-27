@{
    RootModule = 'Interclaw.Bookkeeping.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = 'd4e8f2a1-7b3c-4d5e-9f0a-1b2c3d4e5f6a'
    Author               = 'Interclaw'
    Description          = 'Bookkeeping capability gate — Zoho Books, Vision receipt OCR, Plaid bank sync. Peers with Marketer and Web.'
    PowerShellVersion    = '7.0'
    RequiredModules = @('SalmonRun.Bookkeeping')
    FunctionsToExport = '*'
    PrivateData = @{
        PSData = @{ }
    }
}
