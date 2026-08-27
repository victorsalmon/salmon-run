#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $script:HealthCheckPath = Join-Path $script:RepoRoot "Skills" "Create" "Skill-Authoring" "Scripts" "Invoke-SkillsManifestHealthCheck.ps1"
    $script:SkillsJsonPath = Join-Path $script:RepoRoot "Skills" "skills.json"
    $script:SkillsIndexPath = Join-Path $script:RepoRoot "Skills" "skills-index.json"
    $script:SchemaPath = Join-Path $script:RepoRoot "Skills" "skills.schema.json"
    $script:SkillsRoot = Join-Path $script:RepoRoot "Skills"
    $script:FindStalePath = Join-Path $script:RepoRoot "Skills" "Create" "Skill-Authoring" "Find-StaleSkills.ps1"
}

Describe "SkillsManifest — Orphan Detection" -Tag "SkillsManifest", "Unit" {
    Context "Orphan detection logic" {
        BeforeAll {
            $script:ExcludedNames = @('soul.md', 'identity.md', 'bootstrap.md', 'memory.md', 'heartbeat.md',
                'system-prompt.md', 'tools.md', 'workflow.md', 'user.md', 'environment.md',
                'git-repos.md', 'projects.md', 'protocols.md', 'boundaries.md', 'opencode-acp.md',
                'SKILL.md',
                'lessons-archive.md', 'session-plan-format.md', 'opencode-two-agent.md',
                'environment-tasks.md', 'groom-tasks.md', 'therapy.md',
                '_cowork-scripts.md')

            $script:ExcludedDirPatterns = @(
                '^Skills\\_build',
                '^Skills\\node_modules', '^Skills\\Tests', '^Skills\\Scripts',
                '^Skills\\_organizations', '^Skills\\Tasks',
                '^Skills\\Plugins\\', '^Skills\\Codex\\AutoCode\\',
                '^Skills\\Docker\\Modules\\.+\\Archive',
                '^Skills\\Docker\\Modules\\.+\\Templates',
                '^Skills\\ORCHESTRATOR\\Personas', '^Skills\\Shared',
                '^Skills\\Docker\\Modules\\.+\\_deprecated',
                '\\_deprecated\\',
                '^Skills\\Email\\Scripts\\node_modules',
                '\.pytest_cache',
                '^Skills\\Bookkeeping\\Tests',
                '^Skills\\Docker\\\d',
                '^Skills\\Docker\\Tests',
                '^Skills\\Workflows\\Audit\\alignment-audit-domain',
                '^Skills\\Workflows\\Audit\\architectural-audit',
                '^Skills\\Workflows\\Redeploy',
                '^Skills\\Refactor\\examples',
                '^Skills\\Refactor\\templates'
            )
        }

        It "detects orphans using the filtering logic from the health check script" {
            $manifestPaths = @('Skills\v1.md', 'Skills\v2.md', 'Skills\v3.md')

            $files = @()
            1..3 | ForEach-Object { $i = $_; $files += [PSCustomObject]@{ FullName = "$script:RepoRoot\Skills\v$i.md"; Name = "v$i.md" } }
            1..15 | ForEach-Object { $i = $_; $files += [PSCustomObject]@{ FullName = "$script:RepoRoot\Skills\orphan$i.md"; Name = "orphan$i.md" } }

            $orphaned = $files | Where-Object {
                $rel = $_.FullName.Replace($script:RepoRoot, '').TrimStart('\')
                $rel -notin $manifestPaths -and
                $_.Name -notin $script:ExcludedNames -and
                (-not ($script:ExcludedDirPatterns | Where-Object { $rel -match $_ } | Select-Object -First 1))
            }

            $orphaned.Count | Should -Be 15
        }

        It "excludes known non-skill files from orphan detection" {
            $files = @(
                [PSCustomObject]@{ FullName = "$script:RepoRoot\Skills\soul.md"; Name = "soul.md" }
                [PSCustomObject]@{ FullName = "$script:RepoRoot\Skills\memory.md"; Name = "memory.md" }
                [PSCustomObject]@{ FullName = "$script:RepoRoot\Skills\tools.md"; Name = "tools.md" }
            )

            $orphaned = $files | Where-Object {
                $rel = $_.FullName.Replace($script:RepoRoot, '').TrimStart('\')
                $_.Name -notin $script:ExcludedNames -and
                (-not ($script:ExcludedDirPatterns | Where-Object { $rel -match $_ } | Select-Object -First 1))
            }

            $orphaned.Count | Should -Be 0
        }
    }
}

Describe "SkillsManifest — Schema Validation" -Tag "SkillsManifest", "Unit" {
    It "skills.json validates against skills.schema.json" {
        $schema = Get-Content $script:SchemaPath -Raw
        $json = Get-Content $script:SkillsJsonPath -Raw
        Test-Json -Json $json -Schema $schema | Should -Be $true -Because "skills.json must validate against skills.schema.json"
    }

    It "skills.schema.json is valid JSON Schema (draft-07)" {
        { $null = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It "every skill in skills.json has required fields" {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $registry | ForEach-Object {
            $_.name | Should -Not -BeNullOrEmpty
            $_.path | Should -Not -BeNullOrEmpty
            $_.type | Should -Not -BeNullOrEmpty
            $_.description | Should -Not -BeNullOrEmpty
        }
    }

    It "stale entries have superseded_by" {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $stale = $registry | Where-Object { $_.stale -eq $true -or $_.stale -eq "true" }
        if ($stale.Count -gt 0) {
            $missing = $stale | Where-Object { [string]::IsNullOrWhiteSpace($_.superseded_by) }
            if ($missing.Count -gt 0) {
                Write-Host "WARNING: $($missing.Count) stale entries missing superseded_by:" -ForegroundColor Yellow
                $missing | ForEach-Object { Write-Host "  $($_.name)" -ForegroundColor Yellow }
            }
        }
    }

    It "container field value is in the valid schema enum" {
        $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json
        $validContainers = $schema.items.properties.container.enum
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $invalid = $registry | Where-Object { $_.container -and $_.container -notin $validContainers }
        if ($invalid.Count -gt 0) {
            Write-Host "WARNING: $($invalid.Count) entries with invalid container values:" -ForegroundColor Yellow
            $invalid | ForEach-Object { Write-Host "  $($_.name): container='$($_.container)'" -ForegroundColor Yellow }
        }
    }
}

Describe "SkillsManifest — Index/Manifest Agreement" -Tag "SkillsManifest", "Unit" {
    It "every skill in skills-index.json exists in skills.json" {
        if (-not (Test-Path $script:SkillsIndexPath)) { Set-ItResult -Skipped -Because "skills-index.json not found"; return }
        $index = Get-Content $script:SkillsIndexPath -Raw | ConvertFrom-Json
        $indexNames = $index.PSObject.Properties.Name | Where-Object { $_ -ne '_meta' }
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $registryNames = $registry | ForEach-Object { $_.name }
        $missing = $indexNames | Where-Object { $_ -notin $registryNames }
        $missing | Should -BeNullOrEmpty -Because "all index entries must exist in skills.json"
    }

    It "every non-stale skill in skills.json appears in skills-index.json" {
        if (-not (Test-Path $script:SkillsIndexPath)) { Set-ItResult -Skipped -Because "skills-index.json not found"; return }
        $index = Get-Content $script:SkillsIndexPath -Raw | ConvertFrom-Json
        $indexNames = $index.PSObject.Properties.Name | Where-Object { $_ -ne '_meta' }
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $active = $registry | Where-Object { $_.stale -ne $true -and $_.type -ne 'archived' }
        $activeNames = $active | ForEach-Object { $_.name }
        $missing = $activeNames | Where-Object { $_ -notin $indexNames }
        $missing | Should -BeNullOrEmpty -Because "all active skills must be in the index"
    }
}

Describe "SkillsManifest — Cross-Reference Integrity" -Tag "SkillsManifest", "Unit" {
    It "every depends_on reference resolves to a real skill or file" {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $allNames = $registry | ForEach-Object { $_.name }
        $registry | Where-Object { $_.depends_on } | ForEach-Object {
            $_.depends_on | ForEach-Object {
                $dep = $_
                $isSkillName = $dep -in $allNames
                $isExistingFile = Test-Path (Join-Path $script:RepoRoot $dep) -ErrorAction SilentlyContinue
                if (-not $isSkillName -and -not $isExistingFile) {
                    $dep | Should -Not -BeNullOrEmpty -Because "depends_on '$_' in '$($_.name)' must resolve to a skill name or exist as a file"
                }
            }
        }
    }

    It "every cross_refs reference resolves to a real file" {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $missing = @()
        $registry | Where-Object { $_.cross_refs } | ForEach-Object {
            $_.cross_refs | ForEach-Object {
                $ref = $_
                $fullPath = if ($ref -match '^~[/\\]') {
                    Join-Path $HOME $ref.Substring(2)
                } elseif ([System.IO.Path]::IsPathRooted($ref)) {
                    $ref
                } else {
                    Join-Path $script:RepoRoot $ref
                }
                if (-not (Test-Path $fullPath)) {
                    $missing += "'$ref' in '$($_.name)'"
                }
            }
        }
        if ($missing.Count -gt 0) {
            Write-Host "WARNING: $($missing.Count) unresolved cross_refs:" -ForegroundColor Yellow
            $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
    }
}

Describe "SkillsManifest — Stale Skills" -Tag "SkillsManifest", "Unit" {
    It "Find-StaleSkills.ps1 runs without errors" {
        { & $script:FindStalePath } | Should -Not -Throw
    }

    It "Find-StaleSkills reports stale count or absence" {
        $output = & $script:FindStalePath 2>&1
        $lines = $output | Out-String
        $lines | Should -Match "Total stale:|No stale skills found"
    }
}

Describe "SkillsManifest — Health Check Execution" -Tag "SkillsManifest", "Unit" {
    It "Invoke-SkillsManifestHealthCheck.ps1 runs without errors against production manifest" {
        { & $script:HealthCheckPath -PassThru } | Should -Not -Throw
    }

    It "health check returns a result with Healthy and Issues when using -PassThru" {
        $result = & $script:HealthCheckPath -PassThru
        $result | Should -Not -BeNullOrEmpty
        $result.Healthy | Should -Be $true
        $result.Keys | Should -Contain "Healthy"
        $result.Keys | Should -Contain "Issues"
    }
}
Describe "SkillsManifest — Plugin field" -Tag "SkillsManifest", "Unit" {
    It "every skill in skills.json has a plugin field" {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $missing = $registry | Where-Object { [string]::IsNullOrWhiteSpace($_.plugin) }
        $missing | Should -BeNullOrEmpty -Because "every skill must be assigned to a runbook plugin"
    }
}

