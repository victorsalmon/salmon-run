# Boundary: No credentials — native command wrappers
@{
    RootModule = 'SalmonRun.Process.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'bf479876-47d9-4f74-a6a9-4cebfbfa92cb'
    Author = 'Salmon Run'
    Description = 'Native command wrappers: Invoke-NativeCommand, Invoke-Docker, Test-NativeCommandResult for Interclaw.'
    PowerShellVersion = '7.0'
    RequiredModules = @()
    FunctionsToExport = @('Invoke-NativeCommand','Invoke-AwsCommand','Invoke-Docker','Test-NativeCommandResult')
    PrivateData = @{ PSData = @{ } }
}
