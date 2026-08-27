#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.GitCloud Module" -Tag "GitCloud", "Regression-Only" {
    BeforeAll {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $orchModules = Join-Path $repoRoot 'Modules'
        $skillModules = Join-Path $repoRoot 'Modules'
        $sep = [System.IO.Path]::PathSeparator
        if ($env:PSModulePath) {
            $env:PSModulePath = "$orchModules$sep$skillModules$sep$env:PSModulePath"
        } else {
            $env:PSModulePath = "$orchModules$sep$skillModules"
        }

        $modulePath = Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.GitCloud' 'SalmonRun.GitCloud.psd1'
        $script:GitCloudModule = Import-Module -Name $modulePath -Force -ErrorAction Stop -PassThru
        $env:SALMON_RUN_GITCLOUD_TOKEN = 'fallback-token'
        $env:WORKTREE_HOST = 'https://worktree.example'
    }

    AfterAll {
        Remove-Module SalmonRun.GitCloud -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_READ -ErrorAction SilentlyContinue
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_WRITE -ErrorAction SilentlyContinue
        Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_PUSH -ErrorAction SilentlyContinue
        Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue
    }

    It "exports the expected public functions and aliases" {
        $manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot '..' 'Modules' 'SalmonRun.GitCloud' 'SalmonRun.GitCloud.psd1')
        $expectedFunctions = @(
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
        foreach ($name in $expectedFunctions) {
            $manifest.FunctionsToExport | Should -Contain $name
        }
        $manifest.AliasesToExport | Should -Contain 'Get-GitCloudGitHubToken'
        $manifest.AliasesToExport | Should -Contain 'Get-GitCloudWorktreeToken'
    }

    Context "Token resolution" {
        It "Get-SalmonRunGitCloudToken falls back to the generic token" {
            $result = Get-SalmonRunGitCloudToken -TokenType 'READ'
            $result | Should -Be 'fallback-token'
        }

        It "Get-SalmonRunGitCloudToken prefers a typed env var" {
            $env:SALMON_RUN_GITCLOUD_TOKEN_READ = 'typed-read-token'
            $result = Get-SalmonRunGitCloudToken -TokenType 'READ'
            $result | Should -Be 'typed-read-token'
        }

        It "Select-SalmonRunGitCloudToken maps operations" {
            $env:SALMON_RUN_GITCLOUD_TOKEN_PUSH = 'push-token'
            $result = Select-SalmonRunGitCloudToken -Operation 'push'
            $result | Should -Be 'push-token'
        }

        It "Get-GitHubToken returns GITHUB_TOKEN" {
            $env:GITHUB_TOKEN = 'github-token'
            $result = Get-GitHubToken
            $result | Should -Be 'github-token'
        }

        It "Get-WorktreeToken returns WORKTREE_REPO_RW_ACCESS_TOKEN" {
            $env:WORKTREE_REPO_RW_ACCESS_TOKEN = 'worktree-token'
            $result = Get-WorktreeToken
            $result | Should -Be 'worktree-token'
        }

        It "Get-SalmonRunGitCloudToken honors SecretEnv override" {
            $result = Get-SalmonRunGitCloudToken -TokenType 'READ' -SecretEnv @{ 'SALMON_RUN_GITCLOUD_TOKEN_READ' = 'secret-env-token' }
            $result | Should -Be 'secret-env-token'
        }
    }

    Context "Remote URL" {
        It "resolves GitHub HTTPS URL" {
            $url = Get-SalmonRunGitCloudRemoteUrl -Provider GitHub -Owner 'example' -Repo 'salmon-run'
            $url | Should -Be 'https://github.com/example/salmon-run.git'
        }

        It "resolves Worktree HTTPS URL from the configured host" {
            $url = Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner 'example' -Repo 'salmon-run'
            $url | Should -Be 'https://worktree.example/example/salmon-run.git'
        }

        It "accepts an explicit Worktree host" {
            $url = Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner 'example' -Repo 'salmon-run' -WorktreeHost 'https://git.example'
            $url | Should -Be 'https://git.example/example/salmon-run.git'
        }
    }

    Context "Pushes" {
        It "Push-GitHubRepository throws without a token" {
            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
            { Push-GitHubRepository -Owner 'example' -Repo 'salmon-run' -Token '' } | Should -Throw
        }

        It "Push-WorktreeRepository throws without a token" {
            Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue
            { Push-WorktreeRepository -Owner 'example' -Repo 'salmon-run' -Token '' } | Should -Throw
        }

        It "Push-GitHubRepository mocks git push" {
            Mock -CommandName Invoke-SalmonRunGitCloudPush -ModuleName SalmonRun.GitCloud -MockWith { return [pscustomobject]@{ Success = $true; ExitCode = 0 } }
            $env:GITHUB_TOKEN = 'mocked-token'
            $result = Push-GitHubRepository -Owner 'example' -Repo 'salmon-run' -Branch 'main'
            $result.Success | Should -Be $true
        }
    }

    Context "Worktree API" {
        It "Get-WorktreeCiRun throws without a token" {
            Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue
            { Get-WorktreeCiRun -Owner 'example' -Repo 'salmon-run' } | Should -Throw
        }

        It "Get-WorktreeCiRun returns runs" {
            $env:WORKTREE_REPO_RW_ACCESS_TOKEN = 'mocked-token'
            Mock -CommandName Invoke-RestMethod -ModuleName SalmonRun.GitCloud -MockWith {
                return [pscustomobject]@{ workflow_runs = @(
                    [pscustomobject]@{ run_number = 1; status = 'success'; head_sha = 'abcdef1234567890abcdef1234567890abcdef12' }
                ) }
            }
            $result = Get-WorktreeCiRun -Owner 'example' -Repo 'salmon-run' -Count 1
            $result | Should -HaveCount 1
            $result[0].RunNumber | Should -Be 1
            $result[0].Status | Should -Be 'success'
            $result[0].HeadSha | Should -Be 'abcdef1'
        }

        It "Set-WorktreeRepositorySecret sets a secret" {
            $env:WORKTREE_REPO_RW_ACCESS_TOKEN = 'mocked-token'
            Mock -CommandName Invoke-WebRequest -ModuleName SalmonRun.GitCloud -MockWith { return @{ StatusCode = 201 } }
            $result = Set-WorktreeRepositorySecret -Owner 'example' -Repo 'salmon-run' -Name 'TEST' -Value 'value'
            $result.Success | Should -Be $true
            $result.Name | Should -Be 'TEST'
        }
    }

    Context "Credential resolver integration" {
        BeforeEach {
            $script:__savedSalmonHome = $env:SALMON_RUN_HOME
            $script:__savedWorktreeHost = $env:WORKTREE_HOST
            $script:__savedWorktreeToken = $env:WORKTREE_REPO_RW_ACCESS_TOKEN
            $script:__savedGitHubToken = $env:GITHUB_TOKEN
            $script:__savedGitHubTokenRead = $env:GITHUB_TOKEN_READ
            $script:__savedGitHubTokenWrite = $env:GITHUB_TOKEN_WRITE
            $script:__savedGitHubTokenPush = $env:GITHUB_TOKEN_PUSH
            $script:__savedGitHubTokenStored = $env:GITHUB_TOKEN_STORED
            $script:__savedGenericGitCloudToken = $env:SALMON_RUN_GITCLOUD_TOKEN
            $script:__savedGitCloudTokenRead = $env:SALMON_RUN_GITCLOUD_TOKEN_READ
            $script:__savedGitCloudTokenWrite = $env:SALMON_RUN_GITCLOUD_TOKEN_WRITE
            $script:__savedGitCloudTokenPush = $env:SALMON_RUN_GITCLOUD_TOKEN_PUSH

            $env:SALMON_RUN_HOME = $TestDrive
            Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue
            Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_READ -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_WRITE -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_PUSH -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_STORED -ErrorAction SilentlyContinue
            Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_READ -ErrorAction SilentlyContinue
            Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_WRITE -ErrorAction SilentlyContinue
            Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_PUSH -ErrorAction SilentlyContinue
        }

        AfterEach {
            if ($null -ne $script:__savedSalmonHome) { $env:SALMON_RUN_HOME = $script:__savedSalmonHome } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedWorktreeHost) { $env:WORKTREE_HOST = $script:__savedWorktreeHost } else { Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedWorktreeToken) { $env:WORKTREE_REPO_RW_ACCESS_TOKEN = $script:__savedWorktreeToken } else { Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitHubToken) { $env:GITHUB_TOKEN = $script:__savedGitHubToken } else { Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitHubTokenRead) { $env:GITHUB_TOKEN_READ = $script:__savedGitHubTokenRead } else { Remove-Item Env:\GITHUB_TOKEN_READ -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitHubTokenWrite) { $env:GITHUB_TOKEN_WRITE = $script:__savedGitHubTokenWrite } else { Remove-Item Env:\GITHUB_TOKEN_WRITE -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitHubTokenPush) { $env:GITHUB_TOKEN_PUSH = $script:__savedGitHubTokenPush } else { Remove-Item Env:\GITHUB_TOKEN_PUSH -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitHubTokenStored) { $env:GITHUB_TOKEN_STORED = $script:__savedGitHubTokenStored } else { Remove-Item Env:\GITHUB_TOKEN_STORED -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGenericGitCloudToken) { $env:SALMON_RUN_GITCLOUD_TOKEN = $script:__savedGenericGitCloudToken } else { Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitCloudTokenRead) { $env:SALMON_RUN_GITCLOUD_TOKEN_READ = $script:__savedGitCloudTokenRead } else { Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_READ -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitCloudTokenWrite) { $env:SALMON_RUN_GITCLOUD_TOKEN_WRITE = $script:__savedGitCloudTokenWrite } else { Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_WRITE -ErrorAction SilentlyContinue }
            if ($null -ne $script:__savedGitCloudTokenPush) { $env:SALMON_RUN_GITCLOUD_TOKEN_PUSH = $script:__savedGitCloudTokenPush } else { Remove-Item Env:\SALMON_RUN_GITCLOUD_TOKEN_PUSH -ErrorAction SilentlyContinue }
        }

        It "Get-WorktreeToken resolves a File-resolver token from ~/.salmon/.env" {
            $tokenFile = Join-Path $TestDrive 'worktree-token.txt'
            'file-resolved-token' | Set-Content -LiteralPath $tokenFile -Encoding utf8 -NoNewline
            "WORKTREE_REPO_RW_ACCESS_TOKEN=File $tokenFile" | Set-Content -LiteralPath (Join-Path $TestDrive '.env') -Encoding utf8 -NoNewline

            Get-WorktreeToken | Should -Be 'file-resolved-token'
        }

        It "Get-GitHubToken resolves an Env-resolver token from ~/.salmon/.env" {
            $env:GITHUB_TOKEN_STORED = 'env-resolved-token'
            'GITHUB_TOKEN=Env GITHUB_TOKEN_STORED' | Set-Content -LiteralPath (Join-Path $TestDrive '.env') -Encoding utf8 -NoNewline

            Get-GitHubToken | Should -Be 'env-resolved-token'
        }

        It "Get-SalmonRunGitCloudToken resolves a typed token from ~/.salmon/.env" {
            $env:SALMON_RUN_GITCLOUD_TOKEN_READ_STORED = 'typed-resolved-token'
            'SALMON_RUN_GITCLOUD_TOKEN_READ=Env SALMON_RUN_GITCLOUD_TOKEN_READ_STORED' | Set-Content -LiteralPath (Join-Path $TestDrive '.env') -Encoding utf8 -NoNewline

            Get-SalmonRunGitCloudToken -TokenType 'READ' | Should -Be 'typed-resolved-token'
        }

        It "Get-SalmonRunGitCloudToken falls back to the generic token from ~/.salmon/.env" {
            $env:SALMON_RUN_GITCLOUD_TOKEN_STORED = 'generic-resolved-token'
            'SALMON_RUN_GITCLOUD_TOKEN=Env SALMON_RUN_GITCLOUD_TOKEN_STORED' | Set-Content -LiteralPath (Join-Path $TestDrive '.env') -Encoding utf8 -NoNewline

            Get-SalmonRunGitCloudToken -TokenType 'PUSH' | Should -Be 'generic-resolved-token'
        }

        It "Get-WorktreeHost resolves WORKTREE_HOST from ~/.salmon/.env" {
            'WORKTREE_HOST=https://git.example' | Set-Content -LiteralPath (Join-Path $TestDrive '.env') -Encoding utf8 -NoNewline

            $url = Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner 'example' -Repo 'salmon-run'
            $url | Should -Be 'https://git.example/example/salmon-run.git'
        }
    }
}
