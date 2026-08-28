#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "GitCloud push contract" -Tag "Contract", "Regression" {
    BeforeAll {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $modulesDir = Join-Path $repoRoot 'Modules'
        $sep = [System.IO.Path]::PathSeparator
        $env:PSModulePath = "$modulesDir$sep$env:PSModulePath"

        $modulePath = Join-Path $repoRoot 'Modules' 'SalmonRun.GitCloud' 'SalmonRun.GitCloud.psd1'
        $script:GitCloudModule = Import-Module -Name $modulePath -Force -ErrorAction Stop -PassThru

        $script:GitHubOwner = 'clocklobster'
        $script:GitHubRepo = 'salmon-run'
        $script:WorktreeOwner = 'clocklobster'
        $script:WorktreeRepo = 'salmon-run'
        $script:TestBranch = 'salmon-run/gitcloud-contract'
    }

    AfterAll {
        Remove-Module SalmonRun.GitCloud -Force -ErrorAction SilentlyContinue
    }

    Context "Token resolution through SalmonRun.Credentials" {
        BeforeAll {
            $script:CredHome = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cred-home') -Force
            $script:SavedSalmonHome = $env:SALMON_RUN_HOME
            $env:SALMON_RUN_HOME = $script:CredHome.FullName
            "GITHUB_TOKEN=cred-resolved-github`nWORKTREE_REPO_RW_ACCESS_TOKEN=cred-resolved-worktree`nWORKTREE_HOST=https://cred.worktree.example" |
                Set-Content -LiteralPath (Join-Path $script:CredHome.FullName '.env') -Encoding utf8 -NoNewline

            Remove-Item Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\GITHUB_TOKEN_READ -ErrorAction SilentlyContinue
            Remove-Item Env:\WORKTREE_REPO_RW_ACCESS_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue
        }

        AfterAll {
            if ($null -ne $script:SavedSalmonHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonHome }
            else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
        }

        It "Get-GitHubToken falls back to Get-SalmonRunCredential" {
            Get-GitHubToken | Should -Be 'cred-resolved-github'
        }

        It "Get-WorktreeToken falls back to Get-SalmonRunCredential" {
            Get-WorktreeToken | Should -Be 'cred-resolved-worktree'
        }

        It "Get-WorktreeHost falls back to Get-SalmonRunCredential" {
            & (Get-Module SalmonRun.GitCloud) { Get-WorktreeHost } | Should -Be 'https://cred.worktree.example'
        }
    }

    Context "Authenticated push contract (token is never embedded in the remote URL)" {
        It "Push-GitHubRepository passes the token separately and uses a credential-free URL" {
            $token = 'fake-github-token-12345'
            $expectedUrl = "https://github.com/$($script:GitHubOwner)/$($script:GitHubRepo).git"
            $expectedRef = $script:TestBranch
            Mock -CommandName Invoke-SalmonRunGitCloudPush -ModuleName SalmonRun.GitCloud -MockWith {
                param($RemoteUrl, $RefSpec, $Token)
                return [pscustomobject]@{ Success = $true; ExitCode = 0; Remote = $RemoteUrl; RefSpec = $RefSpec; Token = $Token }
            }

            $result = Push-GitHubRepository -Owner $script:GitHubOwner -Repo $script:GitHubRepo -Branch $expectedRef -Token $token

            $result.Success | Should -Be $true
            Should -Invoke Invoke-SalmonRunGitCloudPush -ModuleName SalmonRun.GitCloud -ParameterFilter {
                $RemoteUrl -eq $expectedUrl -and
                $RemoteUrl -notmatch [regex]::Escape($Token) -and
                $Token -eq $token -and
                $RefSpec -eq $expectedRef
            }
        }

        It "Push-WorktreeRepository passes the token separately and uses a credential-free URL" {
            $token = 'fake-worktree-token-67890'
            $wtHost = 'https://worktree.example'
            $expectedUrl = "$wtHost/$($script:WorktreeOwner)/$($script:WorktreeRepo).git"
            $expectedRef = $script:TestBranch
            Mock -CommandName Invoke-WorktreeGitPush -ModuleName SalmonRun.GitCloud -MockWith {
                param($RemoteUrl, $Branch, $Token)
                return [pscustomobject]@{ Success = $true; ExitCode = 0; Remote = $RemoteUrl; Branch = $Branch; Token = $Token }
            }

            $result = Push-WorktreeRepository -Owner $script:WorktreeOwner -Repo $script:WorktreeRepo -Branch $expectedRef -Token $token -WorktreeHost $wtHost

            $result.Success | Should -Be $true
            Should -Invoke Invoke-WorktreeGitPush -ModuleName SalmonRun.GitCloud -ParameterFilter {
                $RemoteUrl -eq $expectedUrl -and
                $RemoteUrl -notmatch [regex]::Escape($Token) -and
                $Token -eq $token -and
                $Branch -eq $expectedRef
            }
        }
    }

    Context "Live pushes (skipped unless explicitly enabled with real credentials)" {
        BeforeAll {
            # Live pushes require real tokens and must never run in CI or unattended.
            # Enable only by setting SALMON_RUN_GITCLOUD_LIVE=1 with real credentials configured.
            if ($env:SALMON_RUN_GITCLOUD_LIVE -eq '1') {
                $env:SALMON_RUN_HOME = (Join-Path $HOME '.salmon')
            }
        }

        It "live GitHub push is skipped without SALMON_RUN_GITCLOUD_LIVE=1" -Skip:($env:SALMON_RUN_GITCLOUD_LIVE -ne '1') {
            $result = Push-GitHubRepository -Owner $script:GitHubOwner -Repo $script:GitHubRepo -Branch $script:TestBranch
            $result.Success | Should -Be $true
        }

        It "live Worktree push is skipped without SALMON_RUN_GITCLOUD_LIVE=1" -Skip:($env:SALMON_RUN_GITCLOUD_LIVE -ne '1') {
            $result = Push-WorktreeRepository -Owner $script:WorktreeOwner -Repo $script:WorktreeRepo -Branch $script:TestBranch
            $result.Success | Should -Be $true
        }
    }
}
