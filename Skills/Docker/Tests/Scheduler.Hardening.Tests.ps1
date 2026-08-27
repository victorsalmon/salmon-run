#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Scheduler hardening" -Tag "Scheduler", "Robustness" {
    BeforeAll {
        $script:fileHelpersPath = Resolve-Path "Orchestrator/Orchestration/LocalOrchestrator-FileHelpers.ps1"
    }

    Context "Get-FileNamespace regex" {
        It "handles dot-separated dates" {
            . $script:fileHelpersPath
            Get-FileNamespace -FileName "2026.06.25-task1.md" | Should -Be "task1"
        }

        It "handles hyphen-separated dates" {
            . $script:fileHelpersPath
            Get-FileNamespace -FileName "2026-06-25-task1.md" | Should -Be "task1"
        }

        It "handles iteration suffix" {
            . $script:fileHelpersPath
            Get-FileNamespace -FileName "2026.06.25-robustness-0a-test.md" | Should -Be "robustness"
        }
    }

    Context "Sentry auto-actions" {
        It "Sentry entrypoint gates auto-actions behind schedule files" {
            # Check if Sentry entrypoint exists and has schedule file gating
            $found = $false
            $sentryPaths = @(
                "Infrastructure/sentry/entrypoint.ps1",
                "Infrastructure/is-fleet/entrypoint.ps1"
            )
            foreach ($p in $sentryPaths) {
                if (Test-Path $p) {
                    $content = Get-Content $p -Raw -ErrorAction SilentlyContinue
                    if ($content -match 'Tasks/Schedule/') {
                        $found = $true
                    }
                }
            }
            $found | Should -Be $true -Because "Sentry should check for schedule files before auto-actions"
        }
    }
}