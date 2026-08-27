#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.Parent.FullName
    $script:ZohoDir = Join-Path $script:RepoRoot "Skills" "Bookkeeping" "Scripts" "zoho"
}

Describe "ZohoRateLimiter — consolidation" -Tag "Bookkeeping", "Unit", "Zoho", "RateLimit" {
    It "export-zoho-csv.mjs imports ZohoRateLimiter" {
        $content = Get-Content (Join-Path $script:ZohoDir "export-zoho-csv.mjs") -Raw
        $content | Should -Match "import \{ ZohoRateLimiter \} from '\./zoho-rate-limiter\.mjs'"
    }

    It "export-zoho-csv.mjs no longer has inline rate limiter (_lastCall)" {
        $content = Get-Content (Join-Path $script:ZohoDir "export-zoho-csv.mjs") -Raw
        $content | Should -Not -Match "(?m)^let _lastCall ="
    }

    It "export-zoho-csv.mjs no longer has inline rate limiter (_callCount)" {
        $content = Get-Content (Join-Path $script:ZohoDir "export-zoho-csv.mjs") -Raw
        $content | Should -Not -Match "(?m)^let _callCount ="
    }

    It "export-zoho-csv.mjs uses limiter.stats.totalCalls" {
        $content = Get-Content (Join-Path $script:ZohoDir "export-zoho-csv.mjs") -Raw
        $content | Should -Match "limiter\.stats\.totalCalls"
    }

    It "export-zoho-csv.mjs has 429 retry logic" {
        $content = Get-Content (Join-Path $script:ZohoDir "export-zoho-csv.mjs") -Raw
        $content | Should -Match "status === 429"
    }
}

Describe "ZohoRateLimiter — auth bypass fix" -Tag "Bookkeeping", "Unit", "Zoho", "RateLimit" {
    It "post-recon-tx-prune.mjs imports ZohoAuth" {
        $content = Get-Content (Join-Path $script:ZohoDir "post-recon-tx-prune.mjs") -Raw
        $content | Should -Match "import .* ZohoAuth .* from '\./zoho-auth\.js'"
    }

    It "post-recon-tx-prune.mjs no longer imports tokenCache" {
        $content = Get-Content (Join-Path $script:ZohoDir "post-recon-tx-prune.mjs") -Raw
        $content | Should -Not -Match "require\('\./zoho-token-cache\.js'\)"
    }

    It "post-recon-tx-prune.mjs no longer has inline _token variable" {
        $content = Get-Content (Join-Path $script:ZohoDir "post-recon-tx-prune.mjs") -Raw
        $content | Should -Not -Match "(?m)^let _token ="
    }

    It "post-recon-tx-prune.mjs getToken uses ZohoAuth.getInstance" {
        $content = Get-Content (Join-Path $script:ZohoDir "post-recon-tx-prune.mjs") -Raw
        $content | Should -Match "ZohoAuth\.getInstance"
    }

    It "post-recon-tx-prune.mjs apiGet uses limiter.fetchWithRetry" {
        $content = Get-Content (Join-Path $script:ZohoDir "post-recon-tx-prune.mjs") -Raw
        $content | Should -Match "limiter\.fetchWithRetry"
    }

    It "post-recon-tx-prune.mjs deleteTransaction uses limiter.fetchWithRetry" {
        $content = Get-Content (Join-Path $script:ZohoDir "post-recon-tx-prune.mjs") -Raw
        $content | Should -Match "limiter\.fetchWithRetry"
    }
}

Describe "ZohoRateLimiter — 429 retry" -Tag "Bookkeeping", "Unit", "Zoho", "RateLimit" {
    It "zoho-rate-limiter.mjs exports ZohoRateLimiter class" {
        $content = Get-Content (Join-Path $script:ZohoDir "zoho-rate-limiter.mjs") -Raw
        $content | Should -Match "export class ZohoRateLimiter"
    }

    It "zoho-rate-limiter.mjs has fetchWithRetry method" {
        $content = Get-Content (Join-Path $script:ZohoDir "zoho-rate-limiter.mjs") -Raw
        $content | Should -Match "fetchWithRetry"
    }

    It "zoho-rate-limiter.mjs fetchWithRetry checks status 429" {
        $content = Get-Content (Join-Path $script:ZohoDir "zoho-rate-limiter.mjs") -Raw
        $content | Should -Match "response\.status === 429"
    }

    It "zoho-rate-limiter.mjs fetchWithRetry has exponential backoff" {
        $content = Get-Content (Join-Path $script:ZohoDir "zoho-rate-limiter.mjs") -Raw
        $content | Should -Match "Math\.pow\(2, attempt\)"
    }

    It "Sync-TasReceiptStatus.mjs has 429 retry logic" {
        $content = Get-Content (Join-Path $script:ZohoDir "Sync-TasReceiptStatus.mjs") -Raw
        $content | Should -Match "status === 429"
    }
}

Describe "Invoke-Zoho.ps1 — 429 retry" -Tag "Bookkeeping", "Unit", "Zoho", "RateLimit" {
    It "Invoke-Zoho.ps1 has 429 retry in Invoke-ZohoApiCall" {
        $content = Get-Content (Join-Path $script:RepoRoot "Skills" "Bookkeeping" "Scripts" "Invoke-Zoho.ps1") -Raw
        $content | Should -Match "429|TooManyRequests"
    }

    It "Invoke-Zoho.ps1 has exponential backoff for 429" {
        $content = Get-Content (Join-Path $script:RepoRoot "Skills" "Bookkeeping" "Scripts" "Invoke-Zoho.ps1") -Raw
        $content | Should -Match "\[math\]::Pow\(2,"
    }
}

Describe "Invoke-Zoho.ps1 — token reuse (no spurious refresh)" -Tag "Bookkeeping", "Unit", "Zoho", "RateLimit", "Regression" {
    BeforeAll {
        $content = Get-Content (Join-Path $script:RepoRoot "Skills" "Bookkeeping" "Scripts" "Invoke-Zoho.ps1") -Raw
    }

    It "Get-ValidAccessToken fresh-token branch returns cached \$script:headers, not undefined \$headers" {
        $freshBranch = [regex]::Match($content, '(?s)if \(\(Get-Date\) -lt \$script:tokenExpiry\).*?return (\S+)').Groups[1].Value
        $freshBranch | Should -Be '$script:headers'
    }

    It "no bare \$headers reference remains in the fresh-token branch" {
        $content | Should -Not -Match '(?m)^\s*return \$headers\s*$'
    }

    It "retry loop uses -and so it stops when either retry budget is exhausted" {
        $content | Should -Match '\}\s*while \(\$retryCount -lt \$MaxRetries -and \$rateLimitRetryCount -lt \$maxRateRetries\)'
    }

    It "no -or retry condition remains in Invoke-ZohoApiCall" {
        $content | Should -Not -Match 'while \(\$retryCount -lt \$MaxRetries -or \$rateLimitRetryCount'
    }
}
