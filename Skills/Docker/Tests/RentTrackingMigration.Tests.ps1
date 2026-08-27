#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Pester tests for the mcp_web → upscale-havens/backend rent-tracking
# migration (session 2026-08-20-salmon-orchestrator-2-mcp-web-rent-tracking-
# migration). These are static / file-existence tests — they verify the
# migration artifacts exist and the skill docs no longer point at mcp_web
# as the runtime. The Reviewer runs them; do not run them in this session.

BeforeAll {
    $script:SalmonRoot = (Resolve-Path "$PSScriptRoot/../../..").Path
    $script:UpscaleBackend = "C:\Repos\upscale-havens\backend"
}

Describe "RentTracking migration — backend route artifacts" -Tag "RentTracking", "Migration", "Regression" {
    It "backend/src/routes/rent-tracking.ts exists" {
        "$UpscaleBackend/src/routes/rent-tracking.ts" | Should -Exist
    }

    It "backend/src/lib/rent-tracker.ts exists" {
        "$UpscaleBackend/src/lib/rent-tracker.ts" | Should -Exist
    }

    It "backend/src/lib/rent-email-templates.ts exists" {
        "$UpscaleBackend/src/lib/rent-email-templates.ts" | Should -Exist
    }

    It "backend/test/rent-tracking.test.ts exists" {
        "$UpscaleBackend/test/rent-tracking.test.ts" | Should -Exist
    }

    It "backend/src/app.ts mounts /api/rent" {
        $app = Get-Content "$UpscaleBackend/src/app.ts" -Raw
        $app | Should -Match "createRentTrackingRoute"
        $app | Should -Match "/api/rent"
    }

    It "rent-tracking route file mentions propertyId (org-isolation gate)" {
        $route = Get-Content "$UpscaleBackend/src/routes/rent-tracking.ts" -Raw
        $route | Should -Match "propertyId"
    }
}

Describe "RentTracking migration — skill docs no longer point at mcp_web as runtime" -Tag "RentTracking", "Migration", "Regression" {
    It "Skills/RentTracking/SKILL.md frontmatter container is upscale-havens/backend" {
        $skill = Get-Content "$SalmonRoot/Skills/RentTracking/SKILL.md" -Raw
        $skill | Should -Match "container:\s*upscale-havens/backend"
    }

    It "Skills/RentTracking/SKILL.md body references upscale-havens/backend" {
        $skill = Get-Content "$SalmonRoot/Skills/RentTracking/SKILL.md" -Raw
        $skill | Should -Match "upscale-havens/backend"
        $skill | Should -Match "/api/rent/"
    }

    It "Skills/RentTracking/SKILL.md mentions mcp_web only in deprecation/migration notes" {
        $skill = Get-Content "$SalmonRoot/Skills/RentTracking/SKILL.md" -Raw
        # mcp_web may appear in migration/deprecation context but must not be
        # the active runtime reference. The frontmatter container line must
        # not point at mcp_web.
        $skill | Should -Not -Match "container:\s*mcp_web"
    }

    It "Skills/MCP/mcp_web-tools.md notes the rent-tracking migration" {
        $tools = Get-Content "$SalmonRoot/Skills/MCP/mcp_web-tools.md" -Raw
        $tools | Should -Match "MIGRATED"
        $tools | Should -Match "upscale-havens/backend"
    }
}

Describe "RentTracking migration — client-services manifest" -Tag "RentTracking", "Migration", "Regression" {
    It "upscale-havens entry notes the rent-tracking migration" {
        $manifest = Get-Content "$SalmonRoot/Infrastructure/manifests/client-services.json" -Raw
        $manifest | Should -Match "Rent tracking was migrated"
        $manifest | Should -Match "no mcp_web dependency remains"
    }

    It "upscale-havens required services do not include mcp_web" {
        $manifest = Get-Content "$SalmonRoot/Infrastructure/manifests/client-services.json" -Raw |
            ConvertFrom-Json
        $uh = $manifest.clients | Where-Object { $_.name -eq "upscale-havens" }
        $uh.services.required | Should -Not -Contain "mcp_web"
    }
}

Describe "RentTracking migration — legacy seed files retained" -Tag "RentTracking", "Migration", "Regression" {
    It "Infrastructure/rent-tracking/rooms.json is retained as canonical seed" {
        "$SalmonRoot/Infrastructure/rent-tracking/rooms.json" | Should -Exist
    }

    It "Infrastructure/rent-tracking/rooms-data.csv is retained" {
        "$SalmonRoot/Infrastructure/rent-tracking/rooms-data.csv" | Should -Exist
    }

    It "Infrastructure/rent-tracking/rent-tracker.mjs is retained (deprecation cycle)" {
        "$SalmonRoot/Infrastructure/rent-tracking/rent-tracker.mjs" | Should -Exist
    }

    It "Infrastructure/rent-tracking/email-templates.mjs is retained (deprecation cycle)" {
        "$SalmonRoot/Infrastructure/rent-tracking/email-templates.mjs" | Should -Exist
    }
}
