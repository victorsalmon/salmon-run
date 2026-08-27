# Boundary: No credentials — PID files, heartbeats, liveness
@{
    RootModule = 'SalmonRun.AgentLifecycle.psm1'
    ModuleVersion = '1.0.0'
    GUID = '84967d48-7d2d-4e59-97ba-32ffcf41369d'
    Author = 'Salmon Run'
    Description = 'Agent PID file, heartbeat, and stale-agent lifecycle management for Interclaw fleets.'
    PowerShellVersion = '7.0'
    # Uses: Core (Write-AtomicFile), Paths (Get-InterclawRepoRoot), Diagnostics (Write-SetupLog)
    RequiredModules = @('SalmonRun.Core', 'SalmonRun.Diagnostics')
    FunctionsToExport = @('Write-AgentPidFile','Write-AgentHeartbeat','Test-AgentAlive','Clear-StaleAgentFiles')
    PrivateData = @{ PSData = @{ } }
}
