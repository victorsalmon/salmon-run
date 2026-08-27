#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "deploy-lite.ps1" -Tag "Deploy", "DeployLite" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot '..\deploy-lite.ps1'
        $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $script:TestTempDir = Join-Path $env:TEMP "DeployLite-Tests-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestTempDir -Force | Out-Null
        New-Item -ItemType Directory -Path "$($script:TestTempDir)/Tasks/Logs" -Force | Out-Null

        $script:ModulesDir = Join-Path $script:RepoRoot "Skills" "Docker" "Modules"
        if ($env:PSModulePath -notlike "*$($script:ModulesDir)*") {
            $env:PSModulePath = "$($script:ModulesDir);$env:PSModulePath"
        }

        . $script:ScriptPath

        # Record original values for BeforeEach reset
        $script:OriginalRepoRoot = $script:__ocRepoRoot
        $script:OriginalLogLines = $script:LogLines

        # Create fixture data shared across tests
        $script:TestManifest = @{
            version       = 1
            deployed_at   = (Get-Date -Format 'o')
            git_commit    = "abc123def456"
            git_branch    = "main"
            image_version = "local"
            containers    = @{
                "is-fleet"     = @{ image = "fleet:local"; source_hash = "hash1"; git_commit = "abc123def456" }
                "is-api"       = @{ image = "is-api:local"; source_hash = "hash2"; git_commit = "abc123def456" }
                "mcp_opencode" = @{ image = "opencode:local"; source_hash = "hash3"; git_commit = "abc123def456" }
            }
        }
        $script:TestManifestPath = Join-Path $script:TestTempDir "Tasks/Logs/deploy-manifest.json"
        $script:TestManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $script:TestManifestPath -Encoding utf8

        # Standard container list used across tests
        $script:TestContainerList = @("test-container-1", "test-container-2")
    }

    AfterAll {
        if (Test-Path $script:TestTempDir) {
            Remove-Item -Recurse -Force $script:TestTempDir
        }
    }

    Context "Parameter definitions" -Tag "DeployLite" {
        It "has a Containers parameter" {
            $help = Get-Help $script:ScriptPath -Parameter Containers
            $help | Should -Not -BeNullOrEmpty
        }

        It "has an Execute switch" {
            $help = Get-Help $script:ScriptPath -Parameter Execute
            $help | Should -Not -BeNullOrEmpty
        }

        It "has a FleetUrl parameter" {
            $help = Get-Help $script:ScriptPath -Parameter FleetUrl
            $help | Should -Not -BeNullOrEmpty
        }

        It "has a -Json output switch" {
            $help = Get-Help $script:ScriptPath -Parameter Json
            $help | Should -Not -BeNullOrEmpty
        }

        It "has a -Csv output switch" {
            $help = Get-Help $script:ScriptPath -Parameter Csv
            $help | Should -Not -BeNullOrEmpty
        }
    }

    Context "Get-DeployManifest" -Tag "DeployLite" {
        It "returns a manifest object when file exists" {
            $result = Get-DeployManifest
            $result | Should -Not -BeNullOrEmpty
            $result.git_commit | Should -Be "abc123def456"
        }

        It "throws when manifest does not exist" {
            $originalPath = $script:TestManifestPath
            try {
                Remove-Item $script:TestManifestPath -Force
                { Get-DeployManifest } | Should -Throw
            } finally {
                $script:TestManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $originalPath -Encoding utf8
            }
        }
    }

    Context "Get-CodeStaleness" -Tag "DeployLite" {
        BeforeEach {
            $script:__ocRepoRoot = $script:TestTempDir
        }
        AfterEach {
            $script:__ocRepoRoot = $script:OriginalRepoRoot
        }

        It "returns results for all requested containers" {
            $result = Get-CodeStaleness -DeployCommit "abc123def456" -ContainerList @("is-fleet", "is-api")
            $result.Count | Should -Be 2
            $result["is-fleet"] | Should -Not -BeNullOrEmpty
            $result["is-api"] | Should -Not -BeNullOrEmpty
        }

        It "reports code_stale=$false when no changes since deploy commit" {
            $result = Get-CodeStaleness -DeployCommit "abc123def456" -ContainerList @("is-fleet")
            $result["is-fleet"].code_stale | Should -BeFalse
        }

        It "handles empty container list" {
            $result = Get-CodeStaleness -DeployCommit "HEAD" -ContainerList @()
            $result.Count | Should -Be 0
        }

        It "handles nonexistent source paths gracefully" {
            $result = Get-CodeStaleness -DeployCommit "abc123def456" -ContainerList @("nonexistent-container")
            $result["nonexistent-container"].code_stale | Should -BeFalse
        }
    }

    Context "Get-GitState" -Tag "DeployLite" {
        It "returns commit and branch strings" {
            $state = Get-GitState
            $state.Commit | Should -Not -BeNullOrEmpty
            $state.Branch | Should -Not -BeNullOrEmpty
        }
    }

    Context "Build-DecisionTable" -Tag "DeployLite" {
        It "returns skip for all-ok container" {
            $code = @{ "test-container" = @{ code_stale = $false; files_changed = ""; source_hash = $null } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $null -PatternDrift @{ "test-container" = @{ pattern_changed = $false } } -ContainerList @("test-container")
            $rows[0].Action | Should -BeExactly "skip"
        }

        It "returns redeploy for code-stale-only container" {
            $code = @{ "test-container" = @{ code_stale = $true; files_changed = "file1.txt"; source_hash = $null } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $null -PatternDrift @{ "test-container" = @{ pattern_changed = $false } } -ContainerList @("test-container")
            $rows[0].Action | Should -Match "redeploy"
        }

        It "returns refresh-secrets for secrets-stale-only container" {
            $code = @{ "test-container" = @{ code_stale = $false; files_changed = ""; source_hash = $null } }
            $fleet = @{ staleness = @{ "test-container" = @{ secrets_stale = $true } } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $fleet -PatternDrift @{ "test-container" = @{ pattern_changed = $false } } -ContainerList @("test-container")
            $rows[0].Action | Should -BeExactly "refresh-secrets"
        }

        It "returns refresh-secrets for pattern-changed-only container" {
            $code = @{ "test-container" = @{ code_stale = $false; files_changed = ""; source_hash = $null } }
            $pattern = @{ "test-container" = @{ pattern_changed = $true; added_keys = @("new_key"); removed_keys = @() } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $null -PatternDrift $pattern -ContainerList @("test-container")
            $rows[0].Action | Should -BeExactly "refresh-secrets"
        }

        It "returns redeploy+refresh-secrets for code+secrets stale" {
            $code = @{ "test-container" = @{ code_stale = $true; files_changed = "file1"; source_hash = $null } }
            $fleet = @{ staleness = @{ "test-container" = @{ secrets_stale = $true } } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $fleet -PatternDrift @{ "test-container" = @{ pattern_changed = $false } } -ContainerList @("test-container")
            $rows[0].Action | Should -Match "redeploy"
            $rows[0].Action | Should -Match "refresh-secrets"
        }

        It "returns redeploy+refresh-secrets for code+pattern stale" {
            $code = @{ "test-container" = @{ code_stale = $true; files_changed = "file1"; source_hash = $null } }
            $pattern = @{ "test-container" = @{ pattern_changed = $true; added_keys = @("new_key"); removed_keys = @() } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $null -PatternDrift $pattern -ContainerList @("test-container")
            $rows[0].Action | Should -Match "redeploy"
            $rows[0].Action | Should -Match "refresh-secrets"
        }

        It "returns redeploy+refresh-secrets for all-three-stale container" {
            $code = @{ "test-container" = @{ code_stale = $true; files_changed = "file1"; source_hash = $null } }
            $fleet = @{ staleness = @{ "test-container" = @{ secrets_stale = $true } } }
            $pattern = @{ "test-container" = @{ pattern_changed = $true; added_keys = @("new_key"); removed_keys = @() } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $fleet -PatternDrift $pattern -ContainerList @("test-container")
            $rows[0].Action | Should -Match "redeploy"
            $rows[0].Action | Should -Match "refresh-secrets"
        }

        It "does not contain duplicate refresh-secrets" {
            $code = @{ "test-container" = @{ code_stale = $false; files_changed = ""; source_hash = $null } }
            $fleet = @{ staleness = @{ "test-container" = @{ secrets_stale = $true } } }
            $pattern = @{ "test-container" = @{ pattern_changed = $true; added_keys = @("new_key"); removed_keys = @() } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $fleet -PatternDrift $pattern -ContainerList @("test-container")
            $refreshCount = [regex]::Matches($rows[0].Action, "refresh-secrets").Count
            $refreshCount | Should -BeExactly 1
        }

        It "handles container with no bundle type (pattern_changed=$false)" {
            $code = @{ "test-container" = @{ code_stale = $false; files_changed = ""; source_hash = $null } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $null -PatternDrift @{ "test-container" = @{ pattern_changed = $false } } -ContainerList @("test-container")
            $rows[0].Pattern | Should -BeExactly "OK"
        }

        It "reads secrets_stale from freshness fallback when staleness is null" {
            $code = @{ "test-container" = @{ code_stale = $false; files_changed = ""; source_hash = $null } }
            $fleet = @{ freshness = @{ "test-container" = @{ fresh = $false } } }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $fleet -PatternDrift @{ "test-container" = @{ pattern_changed = $false } } -ContainerList @("test-container")
            $rows[0].Action | Should -BeExactly "refresh-secrets"
        }

        It "returns correct results for multiple containers independently" {
            $code = @{
                "c1" = @{ code_stale = $true; files_changed = "f1"; source_hash = $null }
                "c2" = @{ code_stale = $false; files_changed = ""; source_hash = $null }
            }
            $rows = Build-DecisionTable -CodeStaleness $code -FleetStaleness $null -PatternDrift @{ "c1" = @{ pattern_changed = $false }; "c2" = @{ pattern_changed = $false } } -ContainerList @("c1", "c2")
            $rows[0].Action | Should -Match "redeploy"
            $rows[1].Action | Should -BeExactly "skip"
        }
    }

    Context "Get-PatternDrift" -Tag "DeployLite" {
        It "returns results for all requested containers" {
            $result = Get-PatternDrift -DeployCommit "HEAD" -ContainerList @("is-fleet")
            $result | Should -Not -BeNullOrEmpty
            $result["is-fleet"] | Should -Not -BeNullOrEmpty
            $result["is-fleet"].pattern_changed | Should -Not -BeNullOrEmpty
        }

        It "returns pattern_changed=$false for container with no bundle type" {
            $result = Get-PatternDrift -DeployCommit "HEAD" -ContainerList @("nonexistent")
            $result["nonexistent"].pattern_changed | Should -BeFalse
        }
    }

    Context "Error handling and edge cases" -Tag "DeployLite" {
        It "Get-FleetStaleness returns null when both endpoints fail" {
            $result = Get-FleetStaleness -BaseUrl "http://localhost:1" -Token "" -DeployCommit "HEAD" -ContainerList @("test") -ExpectedHashes @{}
            $result | Should -BeNullOrEmpty
        }

        It "Get-DeployManifest throws when manifest is missing" {
            $originalPath = $script:TestManifestPath
            try {
                Remove-Item $script:TestManifestPath -Force
                { Get-DeployManifest } | Should -Throw
            } finally {
                $script:TestManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $originalPath -Encoding utf8
            }
        }

        It "Get-PatternDrift handles missing bundle-manifest.ps1" {
            $result = Get-PatternDrift -DeployCommit "HEAD" -ContainerList @("is-fleet")
            $result["is-fleet"].pattern_changed | Should -Not -BeNullOrEmpty
        }

        It "Invoke-RefreshSecrets handles unreachable Fleet without throwing" {
            $originalWhatIf = $WhatIf
            try {
                $script:LogLines = [System.Collections.Generic.List[string]]::new()
                $script:HadErrors = $false
                Invoke-RefreshSecrets -BaseUrl "http://localhost:1" -Token "" -ContainersToRefresh @("test-container")
                $script:HadErrors | Should -BeTrue
            } finally {
                $script:LogLines = $script:OriginalLogLines.List
            }
        }

        It "Invoke-Redeploy handles unreachable Fleet without throwing" {
            $originalWhatIf = $WhatIf
            try {
                $script:LogLines = [System.Collections.Generic.List[string]]::new()
                $script:HadErrors = $false
                Invoke-Redeploy -BaseUrl "http://localhost:1" -Token "" -ContainersToRedeploy @("test-container")
                $script:HadErrors | Should -BeTrue
            } finally {
                $script:LogLines = $script:OriginalLogLines.List
            }
        }

        It "Invoke-ImageBuild logs warning for unmapped container" {
            try {
                $script:LogLines = [System.Collections.Generic.List[string]]::new()
                $script:HadErrors = $false
                Invoke-ImageBuild -ContainersToBuild @("nonexistent-container")
            } finally {
                $script:LogLines = $script:OriginalLogLines.List
            }
        }

        It "Invoke-RefreshSecrets with empty list does nothing" {
            Invoke-RefreshSecrets -BaseUrl "http://localhost:1" -Token "" -ContainersToRefresh @()
        }

        It "Invoke-Redeploy with empty list does nothing" {
            Invoke-Redeploy -BaseUrl "http://localhost:1" -Token "" -ContainersToRedeploy @()
        }
    }

    Context "Get-FleetToken" -Tag "DeployLite" {
        It "returns the provided token when specified" {
            $result = Get-FleetToken -Token "my-token"
            $result | Should -BeExactly "my-token"
        }

        It "uses FLEET_API_TOKEN env var when no token provided" {
            $env:FLEET_API_TOKEN = "env-token"
            try {
                $result = Get-FleetToken -Token ""
                $result | Should -BeExactly "env-token"
            } finally {
                Remove-Item Env:\FLEET_API_TOKEN -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Comment-based help" -Tag "DeployLite" {
        It "has a .SYNOPSIS section" {
            $help = Get-Help $script:ScriptPath
            $help.Synopsis | Should -Not -BeNullOrEmpty
        }

        It "has parameter help for Containers" {
            $help = Get-Help $script:ScriptPath -Parameter Containers
            $help | Should -Not -BeNullOrEmpty
        }
    }
}
