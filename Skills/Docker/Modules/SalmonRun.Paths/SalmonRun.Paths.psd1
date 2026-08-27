# Boundary: No credentials — path helpers
@{
    RootModule = 'SalmonRun.Paths.psm1'
    ModuleVersion = '1.0.0'
    GUID = '8a4b3c2d-1e5f-4a7b-9c3d-2e8f1a6b4c7d'
    Author = 'Salmon Run'
    Description = 'Path resolution: repo root, home dir, and path cache for SalmonRun. Retains Interclaw.Paths compatibility aliases.'
    PowerShellVersion = '7.0'
    RequiredModules = @()
    FunctionsToExport = @('Get-SalmonRunRepoRoot','Get-HomeDir','Get-SalmonHome','Get-SalmonTaskRoot','Get-RepoRoot','Get-SkillsRoot','Resolve-SkillPath','Reset-SalmonRunPathCache')
    AliasesToExport = @('Get-InterclawRepoRoot','Reset-InterclawPathCache')
    PrivateData = @{ PSData = @{ } }
}
