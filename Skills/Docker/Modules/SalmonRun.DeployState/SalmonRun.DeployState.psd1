# Boundary: No credentials — setup checkpoints, deploy phase invocation
@{
    RootModule = 'SalmonRun.DeployState.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'e369c17f-7a2a-4d3b-9a8c-1b5f2d4e6a7b'
    Author = 'Salmon Run'
    Description = 'Deployment run lifecycle: error tracking, checkpoints, phase orchestration for Interclaw.'
    PowerShellVersion = '7.0'
    # Uses: Core (Write-AtomicFile, Write-AtomicJson), Paths (Get-InterclawRepoRoot), Diagnostics (Write-SetupLog, Get-ReportsDir)
    RequiredModules = @('SalmonRun.Core', 'SalmonRun.Process')
    FunctionsToExport = @('Add-SetupError','Export-SetupErrors','Set-SetupCheckpoint','Test-SetupCheckpoint','Clear-SetupCheckpoints','New-SetupErrorsTasksFile','Invoke-DeployStatePhase','Invoke-CredentialCleanup','Clear-DeployState')
    AliasesToExport = @('Invoke-SetupPhase')
    PrivateData = @{ PSData = @{ } }
}
