#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:moduleRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $script:authPath = Join-Path $script:moduleRoot "Infrastructure/auth/fleet-auth.cjs"
}

Describe "Fleet Auth" -Tag "Core" {
    Context "Syntax validation" {
        It "fleet-auth.cjs has valid Node.js syntax" {
            $result = node --check $script:authPath 2>&1
            $LASTEXITCODE | Should -Be 0
        }
    }

    Context "Hard failure on missing secrets" {
        It "exits with code 1 when secrets missing and dev mode off" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "process\.exit\(1\)"
        }

        It "logs missing secret name before exiting" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "Secret files not found at"
        }

        It "allows dev mode via FLEET_AUTH_DEV_MODE env var" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "FLEET_AUTH_DEV_MODE"
        }

        It "falls open in dev mode when secrets missing" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "allowing all requests \(dev mode\)"
        }
    }

    Context "Constant-time token comparison" {
        It "imports crypto module" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "require\('crypto'\)"
        }

        It "uses timingSafeEqual for token comparison" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "timingSafeEqual"
        }

        It "has length check before timingSafeEqual" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Match "a\.length !== b\.length"
        }

        It "does not use === for token comparison" {
            $src = Get-Content $script:authPath -Raw
            $src | Should -Not -Match "token === serviceToken"
            $src | Should -Not -Match "token === monitorToken"
        }
    }
}
