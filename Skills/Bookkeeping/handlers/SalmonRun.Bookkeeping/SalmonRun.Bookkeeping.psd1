@{
    RootModule = 'SalmonRun.Bookkeeping.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = 'd4e8f2a1-7b3c-4d5e-9f0a-1b2c3d4e5f6a'
    Author               = 'Interclaw'
    Description          = 'Bookkeeping capability gate — Zoho Books, Vision receipt OCR, Plaid bank sync. Peers with Marketer and Web.'
    PowerShellVersion    = '7.0'
    RequiredModules      = @('SalmonRun.Audit')
    FunctionsToExport    = @(
        'Get-BookkeepingSecretBundle',
        'Get-RentStatus',
        'Get-ZohoAccountGeneralLedger',
        'Get-ZohoBalanceSheet',
        'Get-ZohoBankAccounts',
        'Get-ZohoChartOfAccounts',
        'Get-ZohoContacts',
        'Get-ZohoExpenses',
        'Get-ZohoExpense',
        'Get-ZohoGeneralLedger',
        'Get-ZohoInvoices',
        'Get-ZohoProfitAndLoss',
        'Get-ZohoTaxSummary',
        'Get-ZohoTrialBalance',
        'Get-ZohoTransfers',
        'New-ZohoChartOfAccount',
        'New-ZohoContact',
        'New-ZohoExpense',
        'New-ZohoInvoice',
        'New-ZohoTransfer',
        'Update-ZohoExpense',
        'Remove-ZohoExpense',
        'Attach-ReceiptToExpense',
        'Invoke-ReceiptOcr',
        'New-ZohoBankTransaction',
        'New-ZohoCustomerPayment',
        'Get-ZohoJournals',
        'Remove-ZohoJournalEntry'
    )
    PrivateData = @{
        PSData = @{ }
    }
}
