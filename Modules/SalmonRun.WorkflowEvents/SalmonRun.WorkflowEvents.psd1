# Boundary: No credentials — append-only notification board
@{
    RootModule = 'SalmonRun.WorkflowEvents.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'f419cbd2-263f-4852-8b77-eb2963ca183a'
    Author = 'Salmon Run'
    Description = 'Workflow event log (JSONL) for multi-agent coordination via Tasks/Logs/workflow-events.log and namespace-based decision logs via Tasks/Logs/<namespace>.log.'
    PowerShellVersion = '7.0'
    # Uses: Paths (Get-InterclawRepoRoot)
    RequiredModules = @('SalmonRun.Core')
    FunctionsToExport = @('Write-WorkflowEvent','Get-WorkflowEvents','Write-NamespaceLog','Get-NamespaceLog')
    PrivateData = @{ PSData = @{ } }
}
