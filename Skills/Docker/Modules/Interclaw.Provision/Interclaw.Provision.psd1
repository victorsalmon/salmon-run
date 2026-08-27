# Boundary: ReadWrite AWS SM — AWS SSO, IAM, secrets hydration
@{
    RootModule = 'Interclaw.Provision.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'e1d88d4b-6522-474d-87c9-39e1db0ca1f7'
    Author = 'Interclaw'
    Description = 'Provisioning module for Interclaw AWS SSO, IAM, and credential management'
    PowerShellVersion = '7.0'
    # Uses: Core (Get-BackoffDelay, Write-AtomicFile), Paths (Get-InterclawRepoRoot), Diagnostics (Write-SetupLog)
    RequiredModules = @('SalmonRun.Provision')
    FunctionsToExport = '*'
    PrivateData = @{ PSData = @{ } }
}
