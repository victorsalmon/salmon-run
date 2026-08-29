#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Mutation-killing behavioral tests for SalmonRun.GitCloud.

.DESCRIPTION
    These tests are the oracle for Tools/QA/powershell-property-testing
    Invoke-GitCloudMutationAnalysis.ps1. They assert exact behavior of the
    token-resolution and remote-URL functions so that source-level mutants
    (operator/literal/precedence swaps) are detected (killed).
#>

BeforeAll {
    $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
    $modulesDir = if ($env:GITCLOUD_MUTATION_MODULE_ROOT) { $env:GITCLOUD_MUTATION_MODULE_ROOT } else { Join-Path $repoRoot 'Modules' }
    $sep = [System.IO.Path]::PathSeparator
    if ($env:PSModulePath -notlike "*$modulesDir*") {
        $env:PSModulePath = "$modulesDir$sep$env:PSModulePath"
    }

    $modulePath = Join-Path $modulesDir 'SalmonRun.GitCloud' 'SalmonRun.GitCloud.psd1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop

    $script:__saved = @{}
    foreach ($k in @('SALMON_RUN_HOME', 'WORKTREE_HOST', 'GITHUB_TOKEN', 'GITHUB_TOKEN_READ', 'GITHUB_TOKEN_WRITE', 'GITHUB_TOKEN_PUSH', 'WORKTREE_REPO_RW_ACCESS_TOKEN', 'SALMON_RUN_GITCLOUD_TOKEN', 'SALMON_RUN_GITCLOUD_TOKEN_READ', 'SALMON_RUN_GITCLOUD_TOKEN_WRITE', 'SALMON_RUN_GITCLOUD_TOKEN_PUSH')) {
        if (Test-Path Env:\$k) { $script:__saved[$k] = Get-Content Env:\$k }
        else { $script:__saved[$k] = $null }
    }
    $script:__home = Join-Path $TestDrive 'gc-mutation-home'
    $null = New-Item -ItemType Directory -Path $script:__home -Force
    $env:SALMON_RUN_HOME = $script:__home
    foreach ($k in $script:__saved.Keys) { if ($k -ne 'SALMON_RUN_HOME') { Remove-Item Env:\$k -ErrorAction SilentlyContinue } }
}

AfterAll {
    Remove-Module SalmonRun.GitCloud -Force -ErrorAction SilentlyContinue
    foreach ($k in $script:__saved.Keys) {
        if ($null -ne $script:__saved[$k]) { Set-Content Env:\$k -Value $script:__saved[$k] } else { Remove-Item Env:\$k -ErrorAction SilentlyContinue }
    }
}

Describe "GitCloud remote URL (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "GitHub URL is canonical" {
        Get-SalmonRunGitCloudRemoteUrl -Provider GitHub -Owner 'example' -Repo 'salmon-run' | Should -Be 'https://github.com/example/salmon-run.git'
    }

    It "Worktree URL honors an explicit host" {
        Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner 'example' -Repo 'salmon-run' -WorktreeHost 'https://h.example' | Should -Be 'https://h.example/example/salmon-run.git'
    }

    It "Worktree URL falls back to the default host" {
        Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner 'example' -Repo 'salmon-run' | Should -Be 'https://worktree.example/example/salmon-run.git'
    }

    It "Unknown provider throws" {
        { Get-SalmonRunGitCloudRemoteUrl -Provider 'Nope' -Owner 'example' -Repo 'salmon-run' } | Should -Throw
    }
}

Describe "Get-WorktreeHost (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "Env var wins" {
        $env:WORKTREE_HOST = 'https://env.example'
        try { & (Get-Module SalmonRun.GitCloud) { Get-WorktreeHost } | Should -Be 'https://env.example' }
        finally { Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue }
    }

    It "Default host is returned when nothing is configured" {
        Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:__home '.env') -ErrorAction SilentlyContinue
        & (Get-Module SalmonRun.GitCloud) { Get-WorktreeHost } | Should -Be 'https://worktree.example'
    }
}

Describe "Select-SalmonRunGitCloudToken (mutation oracle)" -Tag "GitCloud", "Mutation" {
    BeforeAll {
        $env:SALMON_RUN_GITCLOUD_TOKEN_READ = 'readtok'
        $env:SALMON_RUN_GITCLOUD_TOKEN_WRITE = 'writetok'
        $env:SALMON_RUN_GITCLOUD_TOKEN_PUSH = 'pushtok'
    }
    AfterAll {
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_READ -ErrorAction SilentlyContinue
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_WRITE -ErrorAction SilentlyContinue
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_PUSH -ErrorAction SilentlyContinue
    }
    It "read/clone/fetch resolve the READ token" {
        Select-SalmonRunGitCloudToken -Operation read | Should -Be 'readtok'
        Select-SalmonRunGitCloudToken -Operation clone | Should -Be 'readtok'
        Select-SalmonRunGitCloudToken -Operation fetch | Should -Be 'readtok'
    }
    It "write resolves the WRITE token" {
        Select-SalmonRunGitCloudToken -Operation write | Should -Be 'writetok'
    }
    It "push resolves the PUSH token" {
        Select-SalmonRunGitCloudToken -Operation push | Should -Be 'pushtok'
    }
}

Describe "Get-SalmonRunGitCloudToken (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "SecretEnv wins" {
        Get-SalmonRunGitCloudToken -TokenType READ -SecretEnv @{ SALMON_RUN_GITCLOUD_TOKEN_READ = 'secret' } | Should -Be 'secret'
    }
    It "Typed env var is read" {
        $env:SALMON_RUN_GITCLOUD_TOKEN_READ = 'typed'
        try { Get-SalmonRunGitCloudToken -TokenType READ | Should -Be 'typed' }
        finally { Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_READ -ErrorAction SilentlyContinue }
    }
    It "Generic fallback is read" {
        $env:SALMON_RUN_GITCLOUD_TOKEN = 'generic'
        try { Get-SalmonRunGitCloudToken -TokenType PUSH | Should -Be 'generic' }
        finally { Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN -ErrorAction SilentlyContinue }
    }
}

Describe "Get-GitHubToken (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "GITHUB_TOKEN wins" {
        $env:GITHUB_TOKEN = 'ght'
        try { Get-GitHubToken | Should -Be 'ght' }
        finally { Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue }
    }
    It "Typed suffix GITHUB_TOKEN_READ is read" {
        $env:GITHUB_TOKEN_READ = 'ghr'
        try { Get-GitHubToken -TokenType READ | Should -Be 'ghr' }
        finally { Remove-Item Env:\GITHUB_TOKEN_READ -ErrorAction SilentlyContinue }
    }
    It "SecretEnv wins" {
        Get-GitHubToken -TokenType READ -SecretEnv @{ GITHUB_TOKEN_READ = 'sec' } | Should -Be 'sec'
    }
    It "Credential resolver fallback resolves GITHUB_TOKEN" {
        $env:GH_STORED = 'credval'
        "GITHUB_TOKEN=Env GH_STORED" | Set-Content -LiteralPath (Join-Path $script:__home '.env') -Encoding utf8 -NoNewline
        try { Get-GitHubToken | Should -Be 'credval' }
        finally {
            Remove-Item Env:\GH_STORED -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $script:__home '.env') -ErrorAction SilentlyContinue
        }
    }
}

Describe "Get-WorktreeToken (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "WORKTREE_REPO_RW_ACCESS_TOKEN is read" {
        $env:WORKTREE_REPO_RW_ACCESS_TOKEN = 'wt'
        try { Get-WorktreeToken | Should -Be 'wt' }
        finally { Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue }
    }
    It "SecretEnv wins" {
        Get-WorktreeToken -SecretEnv @{ WORKTREE_REPO_RW_ACCESS_TOKEN = 'sec' } | Should -Be 'sec'
    }
    It "Credential resolver fallback resolves the worktree token" {
        $env:WT_STORED = 'wtcred'
        "WORKTREE_REPO_RW_ACCESS_TOKEN=Env WT_STORED" | Set-Content -LiteralPath (Join-Path $script:__home '.env') -Encoding utf8 -NoNewline
        try { Get-WorktreeToken | Should -Be 'wtcred' }
        finally {
            Remove-Item Env:\WT_STORED -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $script:__home '.env') -ErrorAction SilentlyContinue
        }
    }
}

Describe "Push-GitHubRepository (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "Throws without a token" {
        Mock -CommandName Invoke-SalmonRunGitCloudPush -ModuleName SalmonRun.GitCloud -MockWith { return [pscustomobject]@{ Success = $true; ExitCode = 0 } }
        { Push-GitHubRepository -Owner 'example' -Repo 'salmon-run' -Token '' } | Should -Throw
    }

    It "Builds the canonical GitHub URL and passes the token separately" {
        $captured = $null
        Mock -CommandName Invoke-SalmonRunGitCloudPush -ModuleName SalmonRun.GitCloud -MockWith {
            param($RemoteUrl, $RefSpec, $Token)
            $script:captured = [pscustomobject]@{ RemoteUrl = $RemoteUrl; RefSpec = $RefSpec; Token = $Token }
            return [pscustomobject]@{ Success = $true; ExitCode = 0; Remote = $RemoteUrl; RefSpec = $RefSpec }
        }
        $result = Push-GitHubRepository -Owner 'example' -Repo 'salmon-run' -Branch 'main' -Token 'tok123'
        $result.Success | Should -Be $true
        $script:captured.RemoteUrl | Should -Be 'https://github.com/example/salmon-run.git'
        $script:captured.RefSpec | Should -Be 'main'
        $script:captured.Token | Should -Be 'tok123'
        $script:captured.RemoteUrl | Should -Not -Match 'tok123'
    }
}

Describe "Push-WorktreeRepository (mutation oracle)" -Tag "GitCloud", "Mutation" {
    It "Throws without a token" {
        Mock -CommandName Invoke-WorktreeGitPush -ModuleName SalmonRun.GitCloud -MockWith { return [pscustomobject]@{ Success = $true; ExitCode = 0 } }
        { Push-WorktreeRepository -Owner 'example' -Repo 'salmon-run' -Token '' } | Should -Throw
    }

    It "Builds the canonical Worktree URL and passes the token separately" {
        $captured = $null
        Mock -CommandName Invoke-WorktreeGitPush -ModuleName SalmonRun.GitCloud -MockWith {
            param($RemoteUrl, $Branch, $Token)
            $script:captured = [pscustomobject]@{ RemoteUrl = $RemoteUrl; Branch = $Branch; Token = $Token }
            return [pscustomobject]@{ Success = $true; ExitCode = 0; Remote = $RemoteUrl; Branch = $Branch }
        }
        $result = Push-WorktreeRepository -Owner 'example' -Repo 'salmon-run' -Branch 'main' -Token 'wtok' -WorktreeHost 'https://wt.mutant.example'
        $result.Success | Should -Be $true
        $script:captured.RemoteUrl | Should -Be 'https://wt.mutant.example/example/salmon-run.git'
        $script:captured.Branch | Should -Be 'main'
        $script:captured.Token | Should -Be 'wtok'
        $script:captured.RemoteUrl | Should -Not -Match 'wtok'
    }
}
