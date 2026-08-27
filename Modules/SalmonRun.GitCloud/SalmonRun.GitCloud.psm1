$script:ModuleRoot = $PSScriptRoot

foreach ($f in Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue) {
    . $f.FullName
}

foreach ($f in Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Public') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue) {
    . $f.FullName
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
