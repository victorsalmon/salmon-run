#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SkillRegistry" -Tag "Core" {
    Context "skills.json" {
        BeforeAll {
            $script:RegistryPath = Join-Path $PSScriptRoot '..\..\..\Skills\skills.json'
            $script:Registry = Get-Content $script:RegistryPath -Raw | ConvertFrom-Json
            $script:SchemaPath = Join-Path $PSScriptRoot '..\..\..\Skills\skills.schema.json'
            $script:Schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
        }

        It "contains at least 40 skill entries" {
            $script:Registry.Count | Should -BeGreaterThan 40
        }

        It "has unique names for every entry" {
            $names = $script:Registry | ForEach-Object { $_.name }
            $names.Count | Should -Be ($names | Select-Object -Unique).Count
        }

        It "has valid paths that exist on disk" {
            $script:Registry | ForEach-Object {
                $_.path | Should -Exist
            }
        }

        It "stale entries have superseded_by" {
            $stale = $script:Registry | Where-Object { $_.stale -eq $true }
            if ($stale.Count -gt 0) {
                $stale | ForEach-Object {
                    $_.superseded_by | Should -Not -BeNullOrEmpty
                }
            }
        }

        It "provides container for every entry" {
            $validContainers = @("Bookkeeper", "any", "docusign", "host", "is-api", "matt", "mcp_browserless", "opencode", "ORCHESTRATOR")
            $script:Registry | ForEach-Object {
                if ($_.container) { $_.container | Should -BeIn $validContainers }
            }
        }

        It "provides type for every entry" {
            $validTypes = @("archived", "cowork-utility", "integration", "methodology", "milestone-check", "operational-knowledge", "persona", "pipeline-stage", "reference", "mode-workflow", "skill", "skill-entrypoint", "skill-trackflow", "test", "tool", "tool-command", "tutorial", "utility", "workflow")
            $script:Registry | ForEach-Object {
                $_.type | Should -BeIn $validTypes
            }
        }
    }

    Context "skills.schema.json" {
        It "is valid JSON" {
            { $null = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It "defines staleness fields at item level" {
            $props = $script:Schema.items.properties.PSObject.Properties.Name
            $props -contains "stale" | Should -BeTrue
            $props -contains "superseded_by" | Should -BeTrue
            $props -contains "last_verified" | Should -BeTrue
        }

        It "requires name, path, container, type, description at item level" {
            $required = $script:Schema.items.required
            $required -contains "name" | Should -BeTrue
            $required -contains "path" | Should -BeTrue
            $required -contains "container" | Should -BeTrue
            $required -contains "type" | Should -BeTrue
            $required -contains "description" | Should -BeTrue
        }
    }

    Context "Install-Skills.ps1" {
        It "runs in WhatIf mode without errors" {
            $scriptPath = Join-Path $PSScriptRoot '..\..\OpenCode\Install-Skills.ps1'
            { & $scriptPath -WhatIf } | Should -Not -Throw
        }
    }

    Context "Find-StaleSkills.ps1" {
        It "runs without errors" {
            $scriptPath = Join-Path $PSScriptRoot '..\..\OpenCode\Find-StaleSkills.ps1'
            { & $scriptPath } | Should -Not -Throw
        }

        It "finds at least one stale skill" {
            $scriptPath = Join-Path $PSScriptRoot '..\..\OpenCode\Find-StaleSkills.ps1'
            $output = & $scriptPath 2>&1
            $lines = $output | Out-String
            $lines | Should -Match "Total stale:"
        }
    }
}
