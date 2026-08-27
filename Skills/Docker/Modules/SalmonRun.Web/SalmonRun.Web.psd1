# Boundary: ReadWrite AWS SM — Tavily, Firecrawl, Browserless bundle
@{
    RootModule = 'SalmonRun.Web.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a1b2c3d4-5e6f-7890-abcd-ef1234567890'
    Author               = 'Interclaw'
    Description          = 'Web capability gate — Google Drive, Email, Search (Tavily + Firecrawl). Peers with Bookkeeper and Marketer.'
    PowerShellVersion    = '7.0'
    # Uses: (none detected from exported functions)
    RequiredModules      = @('SalmonRun.Core', 'SalmonRun.Process')
    FunctionsToExport    = @(
        'Get-WebSecretBundle',
        'Invoke-WebSearch'
    )
    PrivateData = @{
        PSData = @{ }
    }
}
