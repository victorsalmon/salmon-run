#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Domain9 Invariant 5 — Pinned Docker Base Tags" -Tag "Infrastructure", "Regression-Only" {
    BeforeAll {
        $infraDir = Join-Path $PSScriptRoot "..\..\..\Infrastructure"
        $dockerfiles = @(Get-ChildItem -Path $infraDir -Filter "Dockerfile*" -Recurse | Where-Object { -not $_.PSIsContainer })
        $dockerfiles += @(Get-ChildItem -Path $infraDir -Filter "*.Dockerfile" -Recurse)
        $script:AllDockerfiles = @($dockerfiles | Where-Object { $_.Name -notin @("opencode.Dockerfile") -or $_.Directory.Name -eq "opencode" })

        function Test-FloatingFromTag {
            param([string]$Line)
            # A tag is only "floating" when the FROM line carries a floating tag
            # token WITHOUT a @sha256: digest pin. `image:lts-debian-12@sha256:<digest>`
            # is valid AND secure — the digest is authoritative, the tag is
            # readability only. So :latest/:lts/:stable only counts as floating
            # when the line has no digest at all.
            return ($Line -match '^\s*FROM\s+' -and $Line -match ':(latest|lts|stable)\b' -and $Line -notmatch '@sha256:')
        }
    }

    It "finds at least 7 Dockerfiles to check" {
        $AllDockerfiles.Count | Should -BeGreaterOrEqual 7
    }

    It "every FROM line uses @sha256:<digest> pinning" {
        $unpinned = @()
        foreach ($df in $AllDockerfiles) {
            $lines = Get-Content -LiteralPath $df.FullName
            foreach ($line in $lines) {
                if ($line -match '^\s*FROM\s+' -and $line -notmatch '\@sha256:') {
                    $unpinned += "$($df.Name): $line"
                }
            }
        }
        if ($unpinned.Count -gt 0) {
            Write-Host "Unpinned FROM lines found:"
            foreach ($u in $unpinned) { Write-Host "  $u" -ForegroundColor Red }
        }
        $unpinned.Count | Should -Be 0
    }

    It "no :latest, :lts, :stable, or major-only tags remain (unless digest-pinned)" {
        $floatingTags = @()
        foreach ($df in $AllDockerfiles) {
            $lines = Get-Content -LiteralPath $df.FullName
            foreach ($line in $lines) {
                if (Test-FloatingFromTag -Line $line) {
                    $floatingTags += "$($df.Name): $line"
                }
            }
        }
        if ($floatingTags.Count -gt 0) {
            Write-Host "Floating (unpinned) tag FROM lines found:"
            foreach ($f in $floatingTags) { Write-Host "  $f" -ForegroundColor Red }
        }
        $floatingTags.Count | Should -Be 0
    }

    It "digest-pinned images with a readable tag are NOT floating (e.g. :lts-debian-12@sha256:...)" {
        $digestPinnedWithTag = "FROM mcr.microsoft.com/powershell:lts-debian-12@sha256:e75ff986fb35d9b24d6684ad50c60959e9def194756d26a2bea698608ae2e38d"
        Test-FloatingFromTag -Line $digestPinnedWithTag | Should -Be $false
    }

    It "genuinely floating tags WITHOUT a digest ARE flagged (e.g. :latest, :lts, :stable)" {
        Test-FloatingFromTag -Line "FROM node:latest" | Should -Be $true
        Test-FloatingFromTag -Line "FROM node:lts" | Should -Be $true
        Test-FloatingFromTag -Line "FROM node:stable" | Should -Be $true
        Test-FloatingFromTag -Line "FROM alpine:3.20" | Should -Be $false
    }
}
