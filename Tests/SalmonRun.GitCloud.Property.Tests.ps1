#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

<#
.SYNOPSIS
    Property-based tests for SalmonRun.GitCloud core token/URL resolution.

.DESCRIPTION
    Uses the lightweight property framework in Tools/QA/powershell-property-testing
    to assert invariants across many generated inputs.
#>

BeforeAll {
    $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
    $modulesDir = Join-Path $repoRoot 'Modules'
    $sep = [System.IO.Path]::PathSeparator
    $env:PSModulePath = "$modulesDir$sep$env:PSModulePath"

    $propertyTool = Join-Path $repoRoot 'Tools' 'QA' 'powershell-property-testing' 'PropertyTesting.ps1'
    . $propertyTool

    $modulePath = Join-Path $repoRoot 'Modules' 'SalmonRun.GitCloud' 'SalmonRun.GitCloud.psd1'
    Import-Module -Name $modulePath -Force -ErrorAction Stop

    function New-TestString {
        [CmdletBinding()]
        param([int]$Seed, [int]$MinLength, [int]$MaxLength, [string]$CharSet)
        $rng = [System.Random]::new($Seed)
        $len = $rng.Next($MinLength, $MaxLength + 1)
        if ($len -le 0) { $len = 1 }
        $chars = @()
        $arr = $CharSet.ToCharArray()
        for ($i = 0; $i -lt $len; $i++) { $chars += $arr[$rng.Next($arr.Length)] }
        return -join $chars
    }

    # Deterministic isolation for host/token resolution.
    $script:__savedSalmonHome = $env:SALMON_RUN_HOME
    $script:__savedWorktreeHost = $env:WORKTREE_HOST
    $env:SALMON_RUN_HOME = Join-Path $TestDrive 'gc-prop-home'
    $null = New-Item -ItemType Directory -Path $env:SALMON_RUN_HOME -Force
    Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue
}

AfterAll {
    Remove-Module SalmonRun.GitCloud -Force -ErrorAction SilentlyContinue
    if ($null -ne $script:__savedSalmonHome) { $env:SALMON_RUN_HOME = $script:__savedSalmonHome } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    if ($null -ne $script:__savedWorktreeHost) { $env:WORKTREE_HOST = $script:__savedWorktreeHost } else { Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue }
}

Describe "GitCloud remote URL properties" -Tag "GitCloud", "Property" {
    It "GitHub URL always ends with .git and embeds owner and repo" {
        $result = Invoke-Property -Description "github-url" -NumRuns 200 -Predicate {
            param($seed)
            $owner = New-TestString -Seed ($seed + 1) -MinLength 1 -MaxLength 20 -CharSet "abcdefghijklmnopqrstuvwxyz0123456789-"
            $repo = New-TestString -Seed ($seed + 2) -MinLength 1 -MaxLength 20 -CharSet "abcdefghijklmnopqrstuvwxyz0123456789-"
            $url = Get-SalmonRunGitCloudRemoteUrl -Provider GitHub -Owner $owner -Repo $repo
            if ($url -ne "https://github.com/$owner/$repo.git") {
                throw "url='$url' owner='$owner' repo='$repo'"
            }
            if (-not $url.EndsWith('.git')) { throw "no .git suffix: $url" }
            if ($url -notmatch [regex]::Escape($owner)) { throw "missing owner: $url" }
            if ($url -notmatch [regex]::Escape($repo)) { throw "missing repo: $url" }
        }
        $result.Passed | Should -Be $true
    }

    It "Worktree URL honors an explicit host and still embeds owner and repo" {
        $result = Invoke-Property -Description "worktree-url" -NumRuns 200 -Predicate {
            param($seed)
            $owner = New-TestString -Seed ($seed + 1) -MinLength 1 -MaxLength 20 -CharSet "abcdefghijklmnopqrstuvwxyz0123456789-"
            $repo = New-TestString -Seed ($seed + 2) -MinLength 1 -MaxLength 20 -CharSet "abcdefghijklmnopqrstuvwxyz0123456789-"
            $hostName = "https://" + (New-TestString -Seed ($seed + 3) -MinLength 8 -MaxLength 24 -CharSet "abcdefghijklmnopqrstuvwxyz0123456789-.")
            $url = Get-SalmonRunGitCloudRemoteUrl -Provider Worktree -Owner $owner -Repo $repo -WorktreeHost $hostName
            if ($url -ne "$hostName/$owner/$repo.git") {
                throw "url='$url' expected='$hostName/$owner/$repo.git'"
            }
            if (-not $url.EndsWith('.git')) { throw "no .git suffix: $url" }
        }
        $result.Passed | Should -Be $true
    }

    It "Unknown provider throws for any input" {
        $gen = New-StringGenerator -MinLength 1 -MaxLength 10 -CharSet "abcdefghijklmnopqrstuvwxyz"
        $result = Invoke-Property -Description "unknown-provider" -NumRuns 50 -Predicate {
            param($seed)
            $owner = & $gen ($seed + 1)
            { Get-SalmonRunGitCloudRemoteUrl -Provider 'Nope' -Owner $owner -Repo 'r' } | Should -Throw
        }
        $result.Passed | Should -Be $true
    }
}

Describe "GitCloud token selection properties" -Tag "GitCloud", "Property" {
    It "Operation maps deterministically to the token for its type" {
        $map = @{ read = 'READ'; clone = 'READ'; fetch = 'READ'; write = 'WRITE'; push = 'PUSH' }
        $result = Invoke-Property -Description "token-map" -NumRuns 100 -Predicate {
            param($seed)
            $val = "tok-$seed"
            foreach ($op in $map.Keys) {
                $envName = "SALMON_RUN_GITCLOUD_TOKEN_$($map[$op])"
                $got = Select-SalmonRunGitCloudToken -Operation $op -SecretEnv @{ $envName = $val }
                if ($got -ne $val) { throw "op=$op got='$got' expected='$val'" }
            }
        }
        $result.Passed | Should -Be $true
    }
}

Describe "GitCloud host resolution properties" -Tag "GitCloud", "Property" {
    It "WORKTREE_HOST env var always wins over the default" {
        $result = Invoke-Property -Description "host-env-precedence" -NumRuns 100 -Predicate {
            param($seed)
            $hostName = "https://" + (New-TestString -Seed ($seed + 1) -MinLength 12 -MaxLength 30 -CharSet "abcdefghijklmnopqrstuvwxyz0123456789-.")
            $saved = $env:WORKTREE_HOST
            $env:WORKTREE_HOST = $hostName
            try {
                $got = & (Get-Module SalmonRun.GitCloud) { Get-WorktreeHost }
                if ($got -ne $hostName) { throw "got='$got' expected='$hostName'" }
            } finally {
                $env:WORKTREE_HOST = $saved
            }
        }
        $result.Passed | Should -Be $true
    }

    It "Empty environment resolves to the public default host" {
        $saved = $env:WORKTREE_HOST
        Remove-Item Env:\WORKTREE_HOST -ErrorAction SilentlyContinue
        try {
            & (Get-Module SalmonRun.GitCloud) { Get-WorktreeHost } | Should -Be 'https://worktree.example'
        } finally {
            if ($null -ne $saved) { $env:WORKTREE_HOST = $saved }
        }
    }
}
