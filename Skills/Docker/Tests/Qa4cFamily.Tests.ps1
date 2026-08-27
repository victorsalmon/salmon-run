#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Qa4cFamily" -Tag "Core", "Regression" {
    Context "canonical family layout" {
        BeforeAll {
            $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
            $script:FamilyRoot = Join-Path $script:RepoRoot "Skills\AQE\4C-Bugfix"
            $script:Gates = @("qa-4c-concern", "qa-4c-cause", "qa-4c-countermeasure", "qa-4c-check", "qa-aqe-bridge")
        }

        It "has the orchestrator qa-4c-bugfix.md at Skills/AQE/4C-Bugfix/qa-4c-bugfix.md" {
            Join-Path $script:FamilyRoot "qa-4c-bugfix.md" | Should -Exist
        }

        It "has all gate skills under the new canonical family path" {
            foreach ($gate in $script:Gates) {
                Join-Path $script:FamilyRoot "$gate.md" | Should -Exist -Because "gate $gate must live in the 4C-Bugfix family"
            }
        }
    }

    Context "manifest registration" {
        BeforeAll {
            $script:RegistryPath = Join-Path $script:RepoRoot "Skills\skills.json"
            $script:Registry = Get-Content $script:RegistryPath -Raw | ConvertFrom-Json
        }

        It "registers 4c-bugfix as the active primary" {
            $entry = $script:Registry | Where-Object { $_.name -eq "4c-bugfix" }
            $entry | Should -Not -BeNullOrEmpty
            $entry.stale | Should -Not -BeTrue
            $entry.path | Should -Exist
            $entry.plugin | Should -Be "aqe"
        }

        It "registers every gate with a resolvable path" {
            $gates = $script:Registry | Where-Object { $_.name -in @("4c-concern", "4c-cause", "4c-countermeasure", "4c-check", "aqe-bridge") }
            $gates.Count | Should -Be 5
            foreach ($g in $gates) { $g.path | Should -Exist }
        }

        It "has no manifest path pointing into the legacy agentic-4c-bugfix gate dirs" {
            $legacyGateHits = $script:Registry | Where-Object { $_.path -like "Skills\QA\agentic-4c-bugfix\4c-*" }
            $legacyGateHits | Should -BeNullOrEmpty
        }
    }

    Context "harness pointer resolution" {
        BeforeAll {
            $script:CanonicalRoot = "C:\Repos\salmon-orchestrator\Skills\AQE\4C-Bugfix"
        }

        It "every .agents/.devin 4c pointer body references an existing canonical file" {
            $pointerDirs = @(
                (Join-Path $script:RepoRoot ".agents\skills"),
                (Join-Path $script:RepoRoot ".devin\skills")
            )
            foreach ($dir in $pointerDirs) {
                Get-ChildItem $dir -Directory -Filter "4c-*" -ErrorAction SilentlyContinue | ForEach-Object {
                    $body = Get-Content (Join-Path $_.FullName "SKILL.md") -Raw
                    if ($body -match 'read and follow `([^`]+\.md)`') {
                        $target = $Matches[1]
                        $target | Should -Exist -Because "pointer $($_.Name) must resolve to a real file"
                        $target | Should -Not -Match "agentic-4c-bugfix\\4c-" -Because "gates must point at the new family path"
                    }
                }
            }
        }

        It "legacy alias pointers forward to the new canonical orchestrator" {
            foreach ($dir in @(".agents", ".devin")) {
                $f = Join-Path $script:RepoRoot "$dir\skills\agentic-4c-bugfix\SKILL.md"
                if (Test-Path $f) {
                    $body = Get-Content $f -Raw
                    $body | Should -Match "Skills.AQE.4C-Bugfix.qa-4c-bugfix\.md" -Because "legacy alias must forward to 4c-bugfix"
                }
            }
        }
    }
}
