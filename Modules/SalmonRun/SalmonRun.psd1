@{
    RootModule = 'SalmonRun.psm1'
    ModuleVersion = '0.1.3'
    GUID = 'a1b2c3d4-1111-2222-3333-444455556666'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Description = 'Top-level meta-module for salmon-run that loads all SalmonRun.* modules: pond engine, agent lifecycle, git cloud, credentials, providers, and supporting subsystems.'
    PowerShellVersion = '7.0'
    RequiredModules = @(
        'SalmonRun.Constants',
        'SalmonRun.Paths',
        'SalmonRun.ModuleLoader',
        'SalmonRun.Core',
        'SalmonRun.Config',
        'SalmonRun.Credentials',
        'SalmonRun.Locking',
        'SalmonRun.Ports',
        'SalmonRun.Process',
        'SalmonRun.AgentLifecycle',
        'SalmonRun.PondEngine',
        'SalmonRun.Display',
        'SalmonRun.Diagnostics',
        'SalmonRun.Audit',
        'SalmonRun.AQE',
        'SalmonRun.Mermaid',
        'SalmonRun.DeployState',
        'SalmonRun.GitCloud',
        'SalmonRun.WorkflowEvents'
    )
    ScriptsToProcess = @()
    FunctionsToExport = @()
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{
        Tags = @('salmon-run', 'kanban', 'agent', 'orchestration')
        LicenseUri = 'https://github.com/victorsalmon/salmon-run/blob/main/LICENSE'
        ProjectUri = 'https://github.com/victorsalmon/salmon-run'
        # The SalmonRun.* submodules ship together in the repository and are
        # installed by install.ps1 rather than published individually to the
        # Gallery, so they are declared external to the package dependency
        # resolver.
        ExternalModuleDependencies = @(
            'SalmonRun.Constants',
            'SalmonRun.Paths',
            'SalmonRun.ModuleLoader',
            'SalmonRun.Core',
            'SalmonRun.Config',
            'SalmonRun.Credentials',
            'SalmonRun.Locking',
            'SalmonRun.Ports',
            'SalmonRun.Process',
            'SalmonRun.AgentLifecycle',
            'SalmonRun.PondEngine',
            'SalmonRun.Display',
            'SalmonRun.Diagnostics',
            'SalmonRun.Audit',
            'SalmonRun.AQE',
            'SalmonRun.Mermaid',
            'SalmonRun.DeployState',
            'SalmonRun.GitCloud',
            'SalmonRun.WorkflowEvents'
        )
    } }
}
