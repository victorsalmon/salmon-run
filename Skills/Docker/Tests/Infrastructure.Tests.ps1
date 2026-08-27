#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
    $rentTracker = Join-Path $repoRoot "Infrastructure/rent-tracking/rent-tracker.mjs"
    $webMcp = Join-Path $repoRoot "Infrastructure/web-mcp-server.js"
}

Describe "rent-tracker.mjs IMAP TLS" -Tag "Infra", "Regression" {
    It "buildImapConfig sets rejectUnauthorized: true" {
        $content = Get-Content $rentTracker -Raw
        $content | Should -Match "tlsOptions:\s*\{ rejectUnauthorized: true \}"
    }
    It "does not disable certificate verification anywhere" {
        $content = Get-Content $rentTracker -Raw
        $content | Should -Not -Match "rejectUnauthorized:\s*false"
    }
}

Describe "web-mcp-server.js IMAP TLS" -Tag "Infra", "Regression" {
    It "buildImapConfig sets rejectUnauthorized: true unconditionally" {
        $content = Get-Content $webMcp -Raw
        $content | Should -Match "tlsOptions:\s*\{ rejectUnauthorized: true \}"
    }
    It "does not read IMAP_TLS_REJECT_UNAUTHORIZED from the environment" {
        $content = Get-Content $webMcp -Raw
        $content | Should -Not -Match "IMAP_TLS_REJECT_UNAUTHORIZED"
    }
    It "does not log an IMAP TLS rejectUnauthorized startup line" {
        $content = Get-Content $webMcp -Raw
        $content | Should -Not -Match "IMAP TLS rejectUnauthorized"
    }
}
