# Boundary: No credentials — port registry lookup
@{
    RootModule = 'SalmonRun.Ports.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'ebbdbc4a-a2b8-40c3-a884-da70cfe35d6a'
    Author = 'Salmon Run'
    Description = 'Port registry lookup: Get-PortRegistry and Get-ServicePort for SalmonRun fleet services.'
    PowerShellVersion = '7.0'
    RequiredModules = @('SalmonRun.Paths','SalmonRun.Diagnostics')
    FunctionsToExport = @('Get-PortRegistry','Get-ServicePort')
    PrivateData = @{ PSData = @{ } }
}
