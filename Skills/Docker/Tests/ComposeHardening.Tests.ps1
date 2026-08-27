#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:moduleRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $script:composePath = Join-Path $script:moduleRoot "Infrastructure/docker-compose.interclaw.yml"
    $script:manifestPath = Join-Path $script:moduleRoot "Infrastructure/manifests/docker-manifest.json"
}

Describe "Compose hardening" -Tag "Deploy" {
    Context "cap_drop and no-new-privileges" {
        It "oc-base-1 has cap_drop: ALL" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "oc-base-1:[\s\S]*?cap_drop:"
        }
        It "oc-base-1 has no-new-privileges" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "oc-base-1:[\s\S]*?no-new-privileges"
        }
        It "is-fleet has cap_drop: ALL" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "is-fleet:[\s\S]*?cap_drop:"
        }
        It "is-fleet has no-new-privileges" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "is-fleet:[\s\S]*?no-new-privileges"
        }
    Context "Host port binding" {
        It "oc-base-1 port bound to 127.0.0.1" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "127.0.0.1:20301:18789"
        }
    Context "max_attempts on restart_policy" {
        It "oc-base-1 has max_attempts: 3" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "oc-base-1[\s\S]*?restart_policy[\s\S]*?max_attempts: 3"
        }
        It "is-fleet has max_attempts set" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "is-fleet[\s\S]*?restart_policy[\s\S]*?max_attempts"
        }
    Context "network isolation" {
        # is-bookkeeping network isolation test removed — service retired 2026-08-21
        It "oc-base has proxy_net and accountant_net" {
            $lines = Get-Content $script:composePath
            $inService = $false
            $hasProxy = $false; $hasAcct = $false
            foreach ($line in $lines) {
                if ($line -match '^  oc-base-1:') { $inService = $true; continue }
                if ($inService -and $line -match '^  \S') { break }
                if ($inService -and $line -match 'proxy_net') { $hasProxy = $true }
                if ($inService -and $line -match 'accountant_net') { $hasAcct = $true }
            }
            $hasProxy | Should -Be $true
            $hasAcct | Should -Be $true
        }
        It "is-fleet has proxy_net and accountant_net" {
            $lines = Get-Content $script:composePath
            $inService = $false
            $hasProxy = $false; $hasAcct = $false
            foreach ($line in $lines) {
                if ($line -match '^  is-fleet:') { $inService = $true; continue }
                if ($inService -and $line -match '^  \S') { break }
                if ($inService -and $line -match 'proxy_net') { $hasProxy = $true }
                if ($inService -and $line -match 'accountant_net') { $hasAcct = $true }
            }
            $hasProxy | Should -Be $true
            $hasAcct | Should -Be $true
        }
        It "proxy_net is declared at top-level networks" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "proxy_net:\s+external: true"
        }
        It "accountant_net is declared at top-level networks" {
            $src = Get-Content $script:composePath -Raw
            $src | Should -Match "accountant_net:\s+external: true"
        }
    }

}