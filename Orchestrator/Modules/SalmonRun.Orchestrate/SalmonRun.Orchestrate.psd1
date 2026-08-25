# Boundary: No credentials — agent dispatch orchestration
@{
    RootModule = 'SalmonRun.Orchestrate.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author = 'Salmon Run'
    CompanyName = 'Salmon Run'
    Copyright = '(c) Salmon Run. All rights reserved.'
    Description = 'Orchestrator module - main loop, queue management, connascence, retry budget, crash throttle, executor variants'
    PowerShellVersion = '7.0'
    # Uses: (none detected from exported functions)
    RequiredModules = @(
        @{ ModuleName = 'SalmonRun.Paths'; ModuleVersion = '1.0.0' }
        @{ ModuleName = 'SalmonRun.Core'; ModuleVersion = '1.0.0' }
        @{ ModuleName = 'SalmonRun.AgentLifecycle'; ModuleVersion = '1.0.0' }
    )
    FunctionsToExport = @('Start-Orchestrator', 'Stop-Orchestrator', 'Get-OrchestratorStatus', 'Get-OrchestratorQueue')
    PrivateData = @{
        PSData = @{
            Tags = @('SalmonRun', 'Orchestrator', 'Deployment')
            ProjectUri = 'https://github.com/salmon-run/salmon-run'
        }
    }
}
