$script:ModuleRoot = $PSScriptRoot

Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    . $_.FullName
}

Export-ModuleMember -Function @(
    # Core
    'Get-SalmonRunGitCloudToken',
    'Select-SalmonRunGitCloudToken',
    'Get-SalmonRunGitCloudRemoteUrl',
    # GitHub
    'Get-GitHubToken',
    'Push-GitHubRepository',
    # Worktree
    'Get-WorktreeToken',
    'Push-WorktreeRepository',
    'Get-WorktreeCiRun',
    'Set-WorktreeRepositorySecret'
) -Alias @(
    'Get-GitCloudGitHubToken',
    'Get-GitCloudWorktreeToken'
)
