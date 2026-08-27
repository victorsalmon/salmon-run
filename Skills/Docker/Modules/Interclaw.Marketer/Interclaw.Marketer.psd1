# Boundary: Read AWS SM — Apollo, ZeroBounce, Smartlead, Hunter secret bundles
@{
    RootModule = 'Interclaw.Marketer.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a7b3c9e1-4d5f-6a8b-9c0d-1e2f3a4b5c6d'
    Author               = 'Interclaw'
    Description          = 'Marketer capability gate — go-to-market operations: Attio CRM, Hunter/Apollo email finders, Smartlead outreach, ZeroBounce validation, Onboarding, Analysis.'
    PowerShellVersion    = '7.0'
    # Uses: (none detected from exported functions)
    RequiredModules = @('SalmonRun.Marketer')
    FunctionsToExport = '*'
    PrivateData = @{
        PSData = @{ }
    }
}
