# Boundary: No credentials — API audit logging, hash-chain signing
@{
    RootModule        = 'SalmonRun.Audit.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e8a7d3f1-5b9c-4a2e-8d6f-1c3b5a7e9d0f'
    Author            = 'Salmon Run'
    CompanyName       = 'Salmon Run'
    Description       = 'Audit logging foundation: hash-chain signed JSONL audit entries, secret-redacted Invoke-ApiCall wrapper, chain integrity verification.'
    PowerShellVersion = '7.0'
    # Uses: Core (Get-BackoffDelay)
    FunctionsToExport = @(
        'Invoke-ApiCall',
        'Write-AuditEntry',
        'Get-AuditTrail',
        'Get-LastHash',
        'Test-AuditChainIntegrity',
        'Protect-JsonFile',
        'Invoke-RedactJsonContent'
    )
    RequiredModules   = @('SalmonRun.Core')
    PrivateData = @{
        PSData = @{
            Tags = @('audit', 'logging', 'hash-chain')
            LicenseUri = ''
            ProjectUri = ''
        }
    }
}
