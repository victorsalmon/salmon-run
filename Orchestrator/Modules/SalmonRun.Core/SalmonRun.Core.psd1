# Boundary: No credentials — core facade, logging, Docker helpers
@{
    RootModule        = 'SalmonRun.Core.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '54da595a-e999-4f15-b10f-46a40b3d271d'
    Author            = 'Salmon Run'
    CompanyName       = 'Salmon Run'
    Copyright         = '(c) Salmon Run. All rights reserved.'
    Description       = 'SalmonRun core module: minimal functions that remain in Core (agent polling loop, dockerfile validation).'
    PowerShellVersion = '5.1'
    # Core is a facade re-exporting Paths, Ports, Diagnostics — see SalmonRun.Core.ps1 for loading logic
    RequiredModules = @('SalmonRun.Paths', 'SalmonRun.Ports', 'SalmonRun.Diagnostics', 'Interclaw.Locking')
    FunctionsToExport = @(
        'Convert-PidSafe',
        'Invoke-AgentPollingLoop',
        'Assert-DockerfileCopyPaths',
        'Lock-File',
        'Unlock-File',
        'Register-Namespace',
        'Remove-NamespaceReservation',
        'Get-BackoffDelay',
        'Invoke-DockerWithLogging',
        'New-CryptographicToken',
        'Write-AtomicFile',
        'Write-AtomicJson',
        'Get-PortRegistry',
        'Get-ServicePort',
        'Get-SalmonRunRepoRoot',
        'Find-SalmonRunModuleData',
        'Write-SetupLog',
        'Test-Step',
        'Get-ReportsDir',
        'Get-DeliverablesDir'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @(
        'Acquire-FileLock',
        'Release-FileLock',
        'Acquire-NamespaceReservation',
        'Release-NamespaceReservation',
        'Reserve-Namespace',
        'Find-InterclawModuleData'
    )
    PrivateData = @{ PSData = @{ } }
}
