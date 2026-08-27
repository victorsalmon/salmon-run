#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Domain9 Invariant 1 — Idempotent Deployment" -Tag "Setup", "Regression-Only" {
    BeforeAll {
        $setupPath = Join-Path $PSScriptRoot "..\deploy.ps1"
        $content = Get-Content -LiteralPath $setupPath -Raw
    }

    It "has -Phase parameter with empty string default" {
        $content | Should -Match '\$Phase\s*=\s*""'
    }

    It "has -WhatIf switch parameter" {
        $content | Should -Match '-WhatIf'
    }

    It "defines Invoke-ConditionalPhase helper for phase filtering" {
        $content | Should -Match "function Invoke-ConditionalPhase"
    }

    It "defines Invoke-WhatIfGuard helper for dry-run" {
        $content | Should -Match "function Invoke-WhatIfGuard"
    }

    It "uses -PhaseName parameter (not -Phase) in Invoke-ConditionalPhase calls" {
        $content | Should -Not -Match "Invoke-ConditionalPhase -Phase\b"
    }

    It "replaces all direct Invoke-SetupPhase -Phase calls with Invoke-ConditionalPhase" {
        $directCalls = [regex]::Matches($content, 'Invoke-SetupPhase\s+-Phase').Count
        $directCalls | Should -Be 0
    }

    It "handles backward compat: Phase=All or empty runs all" {
        $content | Should -Match 'if \(\$Phase -eq "All"\) \{ \$Phase = "" \}'
    }
}
