#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:moduleRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $script:listenerPath = Join-Path $script:moduleRoot "Skills/Docker/Modules/SalmonRun.Fleet/Public/Start-FleetHealthListener.ps1"
    $script:helpersPath = Join-Path $script:moduleRoot "Skills/Docker/Modules/SalmonRun.Fleet/Private/Invoke-FleetHealthHelpers.ps1"
    $script:handlersPath = Join-Path $script:moduleRoot "Skills/Docker/Modules/SalmonRun.Fleet/Private/Invoke-FleetHealthHandlers.ps1"

    # Dot-source the decomposed helper files into the test scope so the
    # git-exec functions are loaded for function-level assertions.
    . $script:helpersPath
    . $script:handlersPath

    $script:listenerSrc = Get-Content $script:listenerPath -Raw
    $script:handlersSrc = Get-Content $script:handlersPath -Raw
    $script:helpersSrc = Get-Content $script:helpersPath -Raw
    $script:combinedSrc = $script:listenerSrc + "`r`n" + $script:helpersSrc + "`r`n" + $script:handlersSrc
}

Describe "IsFleet rehomed git-exec handler" -Tag "Fleet", "Regression" {
    Context "Route registration" {
        It "Start-FleetHealthListener.ps1 dot-sources the private helper files" {
            $script:listenerSrc | Should -Match 'Invoke-FleetHealthHelpers\.ps1'
            $script:listenerSrc | Should -Match 'Invoke-FleetHealthHandlers\.ps1'
        }

        It "Private handlers define POST /api/git/exec route branch" {
            $script:handlersSrc | Should -Match '"/api/git/exec"\s*\{'
        }

        It "'/api/git/exec' is in the writeRoutes array" {
            $script:handlersSrc | Should -Match "'/api/git/exec'"
        }

        It "/api/git/exec is classified as a write route in the listener loop" {
            $script:handlersSrc | Should -Match '\$isWriteRoute\s*=\s*\$writeRoutes\s*-\s*contains\s*\$Path'
        }

        It "/api/git/exec appears in the /api/routes discovery list" {
            $script:handlersSrc | Should -Match 'path\s*=\s*"/api/git/exec"[\s\S]*description\s*=\s*"Execute git commands'
        }

        It "/api/git/exec appears in Get-ToolSpecs" {
            $script:handlersSrc | Should -Match 'name\s*=\s*"git_exec"[\s\S]*description\s*=\s*"Execute git commands'
        }
    }

    Context "Helper function definitions" {
        It "Defines Resolve-GitRepoPath" {
            Get-Command Resolve-GitRepoPath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Defines Invoke-GitStatus" {
            Get-Command Invoke-GitStatus -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Defines Invoke-GitPull" {
            Get-Command Invoke-GitPull -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It "Defines Invoke-GitCommitPush" {
            Get-Command Invoke-GitCommitPush -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    Context "Resolve-GitRepoPath" {
        BeforeEach {
            $env:GIT_REPO_MAPPING = $null
        }

        It "Returns a path from GIT_REPO_MAPPING when repo is mapped" {
            $env:GIT_REPO_MAPPING = '{"custom-repo":"/path/to/custom"}'
            Resolve-GitRepoPath -RepoName 'custom-repo' | Should -Be '/path/to/custom'
        }

        It "Returns the default path for intersite-docs" {
            $env:GIT_REPO_MAPPING = $null
            Resolve-GitRepoPath -RepoName 'intersite-docs' | Should -Be '/home/node/app/repo'
        }

        It "Throws for an unknown repo" {
            { Resolve-GitRepoPath -RepoName 'unknown-repo' } | Should -Throw "*Unknown git repo*"
        }
    }

    Context "Injection guard regexes" {
        It "commit_message injection pattern matches shell chars" {
            $script:handlersSrc | Should -Match 'injectionPattern\s*=\s*''[\s\S]*\\r\\n'
        }

        It "author_email injection pattern rejects spaces and shell chars" {
            $script:handlersSrc | Should -Match 'authorEmail\s*-match\s*''[\s\S]*<>'
        }
    }

    Context "Command dispatch" {
        It "Handles 'status' command" {
            $script:handlersSrc | Should -Match '''status''\s*\{\s*\$output\s*=\s*Invoke-GitStatus'
        }

        It "Handles 'pull' command" {
            $script:handlersSrc | Should -Match '''pull''\s*\{\s*\$output\s*=\s*Invoke-GitPull'
        }

        It "Handles 'commit-push' command" {
            $script:handlersSrc | Should -Match '''commit-push''\s*\{\s*\$files\s*=\s*if\s*\(\s*\$bodyJson\.files'
        }

        It "Rejects unknown commands with UNKNOWN_COMMAND" {
            $script:handlersSrc | Should -Match 'UNKNOWN_COMMAND'
        }
    }
}
