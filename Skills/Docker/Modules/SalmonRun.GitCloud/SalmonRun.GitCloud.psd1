@{
    RootModule             = 'SalmonRun.GitCloud.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'a2f4c8e1-6d3b-4e9a-bc7f-8d1e2f3a4b5c'
    Author                 = 'Salmon Run'
    CompanyName            = 'Salmon Run'
    Description            = 'Git-hosting abstraction for Salmon Run: token resolution, authenticated push, CI status, and repo secrets for GitHub and Gitea-compatible Worktree hosts.'
    PowerShellVersion      = '7.0'
    RequiredModules        = @('SalmonRun.Core')
    FunctionsToExport      = @(
        'Get-SalmonRunGitCloudToken',
        'Select-SalmonRunGitCloudToken',
        'Get-SalmonRunGitCloudRemoteUrl',
        'Get-GitHubToken',
        'Push-GitHubRepository',
        'Get-WorktreeToken',
        'Push-WorktreeRepository',
        'Get-WorktreeCiRun',
        'Set-WorktreeRepositorySecret'
    )
    AliasesToExport        = @(
        'Get-GitCloudGitHubToken',
        'Get-GitCloudWorktreeToken'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('git', 'github', 'worktree', 'gitea', 'ci')
        }
    }
}
