#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
}

Describe "entrypoint.sh — infrastructure hardening" -Tag "Infra", "Entrypoint" {
    It "should replace synchronous DNS gate with non-blocking async check" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint.sh") -Raw
        $content | Should -Not -Match 'wait_for_dependency\(\)'
        $content | Should -Not -Match 'SERVICE_DEPENDENCIES='
        $content | Should -Match 'dns\.lookup.*fire-and-forget'
    }

    It "should validate bundle JSON before processing" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint.sh") -Raw
        $content | Should -Match 'JSON\.parse.*BUNDLE_PATH'
    }

    It "should provide mktemp fallback" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint.sh") -Raw
        $content | Should -Match 'command -v mktemp'
    }

    It "should strip CRLF from JS export script" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint.sh") -Raw
        $content | Should -Match "sed -i 's/\\\r\\\$//'"
    }

    It "should verify temp file creation" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint.sh") -Raw
        $content | Should -Match 'if \[ ! -f "\$_JS_EXPORT_SCRIPT" \]'
    }
}

Describe "entrypoint-web-mcp.sh — DNS gate removal" -Tag "Infra", "Entrypoint" {
    It "should not have wait_for_dependency function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint-web-mcp.sh") -Raw
        $content | Should -Not -Match 'wait_for_dependency\(\)'
    }

    It "should have non-blocking async DNS checks" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint-web-mcp.sh") -Raw
        $content | Should -Match 'dns\.lookup.*fire-and-forget'
    }
}

Describe "opencode/entrypoint.sh — DNS gate removal" -Tag "Infra", "Entrypoint" {
    It "should not have wait_for_dependency function" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/opencode/entrypoint.sh") -Raw
        $content | Should -Not -Match 'wait_for_dependency\(\)'
    }

    It "should have non-blocking async DNS checks" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/opencode/entrypoint.sh") -Raw
        $content | Should -Match 'dns\.lookup.*fire-and-forget'
    }
}

Describe "opencode/entrypoint.sh — shutdown handler PID variable consistency" -Tag "Infra", "Entrypoint", "Regression" {
    It "should reference _opencode_pid (not _openocode_pid) in the shutdown handler" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/opencode/entrypoint.sh") -Raw
        $content | Should -Not -Match '_openocode_pid'
        $content | Should -Match 'kill -TERM "\$_opencode_pid"'
        $content | Should -Match 'wait "\$_opencode_pid"'
        $content | Should -Match '_opencode_pid=\$!'
    }
}

Describe "entrypoint-template.sh — DNS gate deprecated" -Tag "Infra", "Entrypoint" {
    It "should deprecate synchronous DNS gate" {
        $content = Get-Content (Join-Path $repoRoot "Infrastructure/entrypoint-template.sh") -Raw
        $content | Should -Match 'DEPRECATED'
        $content | Should -Not -Match 'wait_for_dependency\(\)'
    }
}

Describe "deploy.ps1 — ForceRebuild and OnlyVerify flags" -Tag "Infra", "Deploy" {
    It "should have ForceRebuild parameter" {
        $content = Get-Content (Join-Path $repoRoot "Skills/Docker/deploy.ps1") -Raw
        $content | Should -Match '\[switch\]\$ForceRebuild'
    }

    It "should have OnlyVerify parameter" {
        $content = Get-Content (Join-Path $repoRoot "Skills/Docker/deploy.ps1") -Raw
        $content | Should -Match '\[switch\]\$OnlyVerify'
    }
}

Describe "Add-ComposeNetworksAndVolumes — shared logs volume" -Tag "Infra", "Compose" {
    It "should declare interclaw_logs volume" {
        $content = Get-Content (Join-Path $repoRoot "Skills/Docker/Modules/SalmonRun.Deploy/Public/Add-ComposeNetworksAndVolumes.ps1") -Raw
        $content | Should -Match 'interclaw_logs'
    }
}

Describe "Start-ParallelImageBuild — ForceRebuild support" -Tag "Infra", "Build" {
    It "should accept ForceRebuild switch" {
        $content = Get-Content (Join-Path $repoRoot "Skills/Docker/Modules/SalmonRun.Images/Public/Start-ParallelImageBuild.ps1") -Raw
        $content | Should -Match '\[switch\]\$ForceRebuild'
    }
}
