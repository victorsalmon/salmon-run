#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Zoho resilience (get-secret, token cache, rate limiter)" -Tag "Bookkeeping", "Zoho", "Regression" {
    BeforeAll {
        $script:testFile = Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\tests\test-zoho-resilience.mjs"
        $script:targets = @(
            (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\shared\lib\get-secret.js")
            (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\zoho\zoho-token-cache.js")
            (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\zoho\zoho-rate-limiter.mjs")
            (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\zoho\zoho-auth.js")
        )
    }

    It "test-zoho-resilience.mjs exists" {
        $script:testFile | Should -Exist
    }

    It "all touched JS/MJS files have valid Node syntax" {
        foreach ($target in $script:targets) {
            $target | Should -Exist
            $result = & node --check $target 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "node --check $target should pass; got: $result"
        }
    }

    It "get-secret.js surfaces actionable SSO guidance on failure" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\shared\lib\get-secret.js") -Raw
        $content | Should -Match 'AWS SSO session expired'
        $content | Should -Match 'dev-daily-fixed'
        $content | Should -Match 'wrapped\.cause'
        $content | Should -Not -Match "AWS_SSO_PROFILE \|\| 'interclaw'"
    }

    It "zoho-token-cache.js derives volume name from INSTALL_PROJECT" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\zoho\zoho-token-cache.js") -Raw
        $content | Should -Match 'process\.env\.INSTALL_PROJECT \|\| .FRAD.'
        $content | Should -Match '\$\{PROJECT_CODE\}_zoho_token_cache'
        $content | Should -Match 'docker volume inspect'
    }

    It "zoho-rate-limiter.mjs retries network errors and 5xx" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\..\Bookkeeper\Scripts\zoho\zoho-rate-limiter.mjs") -Raw
        $content | Should -Match 'status === 429 \|\| response\.status >= 500'
        $content | Should -Match 'catch \(err\)'
        $content | Should -Match 'Network error'
    }

    It "runs the Node unit test suite successfully" {
        $output = & node $script:testFile 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "zoho resilience unit tests should pass; output: $output"
        ($output -join "`n") | Should -Match 'All zoho-resilience tests passed'
    }
}
