@{
    RootModule           = 'SalmonRun.Mermaid.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author               = 'Salmon Run'
    Description          = 'Extract and chunk repository Mermaid diagrams for model ingestion.'
    PowerShellVersion    = '7.0'
    RequiredModules      = @()
    FunctionsToExport    = @(
        'Get-RepoMermaidChunks'
        'Split-RepoMermaidChunks'
    )
    AliasesToExport      = @()
    PrivateData = @{
        PSData = @{ }
    }
}
