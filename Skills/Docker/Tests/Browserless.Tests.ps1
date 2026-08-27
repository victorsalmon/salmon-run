#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
}

Describe "mcp_browserless.Dockerfile" -Tag "Browserless" {
    It "sets ENV PORT=3003" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/mcp_browserless.Dockerfile") -Raw
        $content | Should -Match "ENV PORT=3003"
    }
    It "does not reference PORT=21006" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/mcp_browserless.Dockerfile") -Raw
        $content | Should -Not -Match "PORT=21006"
    }
    It "EXPOSE 3003 is present" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/mcp_browserless.Dockerfile") -Raw
        $content | Should -Match "EXPOSE 3003"
    }
}

Describe "browserless-wrapper.sh" -Tag "Browserless" {
    It "sets PORT=3003" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/browserless-wrapper.sh") -Raw
        $content | Should -Match "PORT=3003"
    }
    It "does not reference PORT=21006" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/browserless-wrapper.sh") -Raw
        $content | Should -Not -Match "PORT=21006"
    }
    It "healthcheck targets 127.0.0.1:3003/pressure" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/browserless-wrapper.sh") -Raw
        $content | Should -Match "127.0.0.1:3003/pressure"
    }
}

Describe "port-registry.json" -Tag "Browserless" {
    It "mcp_browserless port is 3003" {
        $registry = Get-Content (Join-Path $repoRoot "Infrastructure/port-registry.json") -Raw | ConvertFrom-Json
        $registry.internal.mcp_browserless | Should -Be 3003
    }
    It "has upstream_internal range" {
        $registry = Get-Content (Join-Path $repoRoot "Infrastructure/port-registry.json") -Raw | ConvertFrom-Json
        $registry.ranges.upstream_internal.start | Should -Be 3000
        $registry.ranges.upstream_internal.end | Should -Be 3999
    }
}

Describe "browserless-server.js" -Tag "Browserless" {
    It "server file exists at Infrastructure/Browserless/browserless-server.js" {
        $path = Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js"
        Test-Path $path | Should -Be $true
    }
    It "has Amazon download endpoint handler" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "/tools/amazon/download-receipts"
    }
    It "has AliExpress download endpoint handler" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "/tools/aliexpress/download-receipts"
    }
    It "has Amazon login endpoint handler" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "/tools/amazon/login"
    }
    It "has AliExpress login endpoint handler" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "/tools/aliexpress/login"
    }
    It "references amazon-persistent-downloader.js" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "amazon-persistent-downloader"
    }
    It "references aliexpress-persistent-downloader.js" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "aliexpress-persistent-downloader"
    }
    It "listens on BROWSERLESS_SERVER_PORT with fallback to 3099" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "3099"
    }
    It "has health endpoint" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "/health"
    }
}

Describe "browserless-server-start.ps1" -Tag "Browserless" {
    It "start script exists" {
        $path = Join-Path $repoRoot "Infrastructure/Browserless/browserless-server-start.ps1"
        Test-Path $path | Should -Be $true
    }
    It "has Background switch parameter" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server-start.ps1") -Raw
        $content | Should -Match '\$Background'
    }
}

Describe "browserless-server.js parseBody size limit" -Tag "Browserless" {
    It "defines MAX_BODY_SIZE at 1MB" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "MAX_BODY_SIZE = 1024 \* 1024"
    }
    It "parseBody checks Content-Length header" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "content-length"
    }
    It "parseBody returns err.statusCode 413 on oversized payload" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "err.statusCode = 413"
    }
    It "handleDownload returns 413 for oversized body" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "err.statusCode === 413"
        $content | Should -Match "Request body too large"
    }
}

Describe "browserless-server.js startup script validation" -Tag "Browserless" {
    It "validates scripts at startup" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "node --check"
    }
    It "marks broken sites" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "cfg._broken"
    }
    It "handleDownload returns 503 for broken sites" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "is broken"
    }
    It "/ready endpoint reports broken field" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "broken"
    }
}

Describe "browserless-server.js session slot safety" -Tag "Browserless" {
    It "uses slotReleased flag to prevent double-release" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "slotReleased"
    }
    It "close handler releases slot via finally" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "finally"
    }
    It "error handler releases slot via finally" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "finally"
    }
    It "external try/catch releases slot on sync error" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "catch \(err\)"
    }
    It "version bumped to 1.3" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "VERSION = '1.3'"
    }
}

Describe "browserless-server.js session slot atomicity" -Tag "Browserless", "Regression" {
    It "no await between capacity check and activeSessions++" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $checkIdx = $content.IndexOf("if (activeSessions >= MAX_CONCURRENT_SESSIONS)")
        $checkIdx | Should -BeGreaterThan -1
        $incIdx = $content.IndexOf("activeSessions++", $checkIdx)
        $incIdx | Should -BeGreaterThan -1
        $between = $content.Substring($checkIdx, $incIdx - $checkIdx)
        $between | Should -Not -Match "await"
    }
    It "capacity re-check happens after the gap-await" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $checkIdx = $content.IndexOf("if (activeSessions >= MAX_CONCURRENT_SESSIONS)")
        $gapIdx = $content.IndexOf("setTimeout(r, gap)")
        $gapIdx | Should -BeLessThan $checkIdx
    }
    It "logs SESSION_OVERCAPACITY when the cap is exceeded" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "SESSION_OVERCAPACITY"
    }
    It "SESSION_OVERCAPACITY guard includes actual and max counts" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "active_sessions="
        $content | Should -Match "max_concurrent="
    }
    It "acquireSessionSlot claims slot before returning sessionId" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $checkIdx = $content.IndexOf("if (activeSessions >= MAX_CONCURRENT_SESSIONS)")
        $returnIdx = $content.IndexOf("return sessionId", $checkIdx)
        $returnIdx | Should -BeGreaterThan -1
        $claim = $content.Substring($checkIdx, $returnIdx - $checkIdx)
        $claim | Should -Match "activeSessions\+\+"
        $claim | Should -Not -Match "await"
    }
}

Describe "browserless-server.js imports execSync" -Tag "Browserless" {
    It "imports execSync from child_process" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "execSync"
    }
}

Describe "lib/re-auth.js" -Tag "Browserless" {
    It "re-auth.js exists" {
        $path = Join-Path $repoRoot "Infrastructure/Browserless/lib/re-auth.js"
        Test-Path $path | Should -Be $true
    }
    It "exports reauthenticate function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/lib/re-auth.js") -Raw
        $content | Should -Match "reauthenticate"
    }
    It "uses spawnSync to run re-auth scripts" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/lib/re-auth.js") -Raw
        $content | Should -Match "spawnSync"
    }
    It "passes --timeout argument" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/lib/re-auth.js") -Raw
        $content | Should -Match "--timeout"
    }
}

Describe "Amazon downloader re-auth" -Tag "Browserless" {
    It "imports reauthenticate" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "re-auth"
    }
    It "defines REAUTH_SCRIPT" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "REAUTH_SCRIPT"
    }
    It "calls reauthenticate on session loss" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "reauthenticate"
    }
    It "re-launches browser after re-auth" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "chromium.launchPersistentContext"
    }
}

Describe "Netflix downloader re-auth" -Tag "Browserless" {
    It "imports reauthenticate" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/netflix.com/netflix-receipt-downloader.js") -Raw
        $content | Should -Match "re-auth"
    }
    It "defines REAUTH_SCRIPT" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/netflix.com/netflix-receipt-downloader.js") -Raw
        $content | Should -Match "REAUTH_SCRIPT"
    }
    It "calls reauthenticate on session loss" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/netflix.com/netflix-receipt-downloader.js") -Raw
        $content | Should -Match "reauthenticate"
    }
}

Describe "Home Depot downloader re-auth" -Tag "Browserless" {
    It "imports reauthenticate" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "re-auth"
    }
    It "defines REAUTH_SCRIPT" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "REAUTH_SCRIPT"
    }
    It "calls reauthenticate on session loss" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "reauthenticate"
    }
}

Describe "AliExpress downloader re-auth" -Tag "Browserless" {
    It "imports reauthenticate" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/aliexpress.com/aliexpress-persistent-downloader.js") -Raw
        $content | Should -Match "re-auth"
    }
    It "defines REAUTH_SCRIPT" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/aliexpress.com/aliexpress-persistent-downloader.js") -Raw
        $content | Should -Match "REAUTH_SCRIPT"
    }
    It "calls reauthenticate on session loss" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/aliexpress.com/aliexpress-persistent-downloader.js") -Raw
        $content | Should -Match "reauthenticate"
    }
}

Describe "browserless-server.js session leak detector" -Tag "Browserless", "Regression" {
    It "defines activeSessionIds Set" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "activeSessionIds"
    }
    It "defines getSessionLeakInfo function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "getSessionLeakInfo"
    }
    It "returns leaked session count in getSessionLeakInfo" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "leaked"
    }
    It "has shutdown handler for SIGINT/SIGTERM" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "SIGINT"
        $content | Should -Match "SIGTERM"
    }
    It "shutdown calls getSessionLeakInfo" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "shutdown"
    }
    It "health endpoint includes concurrency details" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "concurrency"
    }
    It "acquireSessionSlot returns sessionId string" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "return sessionId"
    }
    It "acquireSessionSlot returns null on capacity" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "return null"
    }
    It "handleDownload uses sessionId for slot tracking" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "releaseSessionSlot\(sessionId\)"
    }
    It "response includes valid_files field" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "valid_files"
    }
    It "response includes file size validation via fs.statSync" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "fs.statSync"
    }
}

Describe "Amazon downloader --discover mode" -Tag "Browserless", "Regression" {
    It "has parseArgs function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "parseArgs"
    }
    It "handles --discover flag" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "'--discover'"
    }
    It "has runDiscovery function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "runDiscovery"
    }
    It "validates output file size after save" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "fs.statSync"
    }
    It "dispatches discovery mode in main" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/amazon.ca/amazon-persistent-downloader.js") -Raw
        $content | Should -Match "opts.discover"
    }
}

Describe "Netflix downloader output validation" -Tag "Browserless", "Regression" {
    It "validates output file sizes" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/netflix.com/netflix-receipt-downloader.js") -Raw
        $content | Should -Match "validCount"
    }
}

Describe "Home Depot downloader --discover mode" -Tag "Browserless", "Regression" {
    It "handles --discover flag" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "'--discover'"
    }
    It "has runDiscovery function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "runDiscovery"
    }
    It "validates output file size" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "fs.statSync"
    }
    It "dispatches discovery mode in main" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/homedepot.ca/homedepot-receipt-downloader.js") -Raw
        $content | Should -Match "opts.discover"
    }
}

Describe "AliExpress downloader output validation" -Tag "Browserless", "Regression" {
    It "validates screenshot file size after capture" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/Sites/aliexpress.com/aliexpress-persistent-downloader.js") -Raw
        $content | Should -Match "fs.statSync"
    }
}

Describe "browserless.md documentation" -Tag "Browserless" {
    It "does not claim port 21006" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless.md") -Raw
        $content | Should -Not -Match "21006"
    }
    It "references ADR 0014 upstream-dictated range" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless.md") -Raw
        $content | Should -Match "upstream-dictated"
    }
}

Describe "browserless-server.js fleet auth gate" -Tag "Browserless", "Regression" {
    It "defines AUTH_EXEMPT_PATHS with /health and /ready" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "AUTH_EXEMPT_PATHS"
        $content | Should -Match "'/health'"
        $content | Should -Match "'/ready'"
    }
    It "defines isAuthenticated bearer check" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "function isAuthenticated"
        $content | Should -Match "Bearer "
    }
    It "uses timing-safe comparison for the token" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "timingSafeEqual"
        $content | Should -Match "a\.length !== b\.length"
    }
    It "returns 403 for unauthenticated non-exempt requests" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "isAuthenticated\(req\)"
        $content | Should -Match "403"
    }
    It "fails closed when the token file is missing or empty" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "process\.exit\(1\)"
        $content | Should -Match "BROWSERLESS_AUTH_DEV_MODE"
    }
    It "reads the token from BROWSERLESS_FLEET_TOKEN_FILE" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "BROWSERLESS_FLEET_TOKEN_FILE"
    }
    It "does not set Access-Control-Allow-Origin wildcard" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Not -Match "Access-Control-Allow-Origin', '\*'"
    }
    It "restricts CORS to configured origin" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "CORS_ORIGIN"
    }
}

Describe "browserless-server.js output_dir validation" -Tag "Browserless", "Regression" {
    It "defines resolveOutputDir validator" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "function resolveOutputDir"
    }
    It "rejects traversal in output_dir" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "must not contain"
    }
    It "rejects paths outside allowed roots with 400" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "outside allowed roots"
        $content | Should -Match "err.statusCode = 400"
    }
    It "passes only the validated absolute path as OUTPUT_DIR" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server.js") -Raw
        $content | Should -Match "env.OUTPUT_DIR = resolvedOutputDir"
    }
}

Describe "browserless-server-start.ps1 auth wiring" -Tag "Browserless", "Regression" {
    It "documents the auth requirement in the header" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server-start.ps1") -Raw
        $content | Should -Match "AUTH REQUIREMENT"
    }
    It "sets BROWSERLESS_FLEET_TOKEN_FILE from -TokenFile" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/Browserless/browserless-server-start.ps1") -Raw
        $content | Should -Match "BROWSERLESS_FLEET_TOKEN_FILE"
        $content | Should -Match "TokenFile"
    }
}
