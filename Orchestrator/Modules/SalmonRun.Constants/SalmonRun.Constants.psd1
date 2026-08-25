# Boundary: No credentials — read-only constants
@{
    RootModule = 'SalmonRun.Constants.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'fe9dac4e-6179-4dc4-9f4c-a70c3b6f87b0'
    Author = 'Salmon Run'
    Description = 'Fleet-wide constants, network names, default region, and coding key priority for SalmonRun. Retains Interclaw.Constants compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Ports', 'SalmonRun.Config', 'SalmonRun.Diagnostics')
    FunctionsToExport = @('Get-SalmonRunConstants','Get-NetworkNames','Get-DefaultRegion','Get-CodingKeyPriority','Get-ProjectCode')
    AliasesToExport = @('Get-InterclawConstants')
    PrivateData = @{ PSData = @{ } }
}
