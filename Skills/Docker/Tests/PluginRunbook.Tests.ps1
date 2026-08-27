#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.Parent.Parent.FullName
    $script:PluginsRoot = Join-Path $script:RepoRoot 'Plugins'
    $script:SkillsRoot = Join-Path $script:RepoRoot 'Skills'
    $script:SkillsJsonPath = Join-Path $script:RepoRoot 'Skills' 'skills.json'

    function Get-RunbookFrontmatter {
        param([string]$Path)
        $content = Get-Content $Path -Raw
        if ($content -match '^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)$') {
            return @{
                Frontmatter = $matches[1]
                Body        = $matches[2]
            }
        }
        return $null
    }

    function Get-FrontmatterValue {
        param([string]$Frontmatter, [string]$Key)
        $lines = $Frontmatter -split '\r?\n'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^$([regex]::Escape($Key)):\s*(.*)") {
                $value = $matches[1].Trim()
                # If the value is a YAML folded block (> ...) continue collecting indented/blank lines.
                if ($value -eq '>' -or $value -eq '|') {
                    $value = ''
                    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                        if ($lines[$j] -match '^\s+\S' -or $lines[$j] -match '^\s*$') {
                            $value += ' ' + $lines[$j].Trim()
                            $i = $j
                        } else {
                            break
                        }
                    }
                }
                return $value.Trim()
            }
        }
        return $null
    }

    function Get-MasterChildRunbooks {
        param([string]$Body)
        if ($Body -notmatch '## Included runbooks') { return @() }
        $section = ($Body -split '## Included runbooks')[1]
        if ($section -match '## ') {
            $section = ($section -split '^## ', 0, 'Multiline')[0]
        }
        $children = [regex]::Matches($section, '(?m)^\s*-\s+\*\*([\w\-]+)\*\*') | ForEach-Object { $_.Groups[1].Value }
        return $children
    }

    function Get-CanonicalSkillPaths {
        param([string]$Body)
        $paths = [regex]::Matches($Body, 'Canonical:\s*`+([^`]+)`+') | ForEach-Object {
            $_.Groups[1].Value
        }
        return $paths
    }

    function Get-RunbookFiles {
        param([string]$Root)
        Get-ChildItem -Path $Root -Filter 'SKILL.md' -Recurse -File |
            Where-Object { $_.FullName -match '\\Plugins\\[^\\]+\\skills\\[^\\]+\\SKILL\.md$' }
    }

    $script:AllRunbooks = Get-RunbookFiles -Root $script:PluginsRoot
    $script:AllPlugins = Get-ChildItem -Path $script:PluginsRoot -Directory | Where-Object { $_.Name -ne 'node_modules' -and (Test-Path (Join-Path $_.FullName '.devin-plugin' 'plugin.json')) }
}

Describe 'PluginRunbook — Plugin Manifests' -Tag 'PluginRunbook', 'Unit', 'Regression' {
    It 'discovers at least one plugin and one runbook' {
        $script:AllPlugins.Count | Should -BeGreaterThan 0 -Because 'the Plugins directory must contain valid plugin directories'
        $script:AllRunbooks.Count | Should -BeGreaterThan 0 -Because 'each plugin should expose runbooks at skills/<name>/SKILL.md'
    }

    It 'every plugin directory has a valid .devin-plugin/plugin.json' {
        $script:AllPlugins | ForEach-Object {
            $pluginName = $_.Name
            $pluginJsonPath = Join-Path $_.FullName '.devin-plugin' 'plugin.json'
            Test-Path $pluginJsonPath | Should -Be $true -Because "$pluginName must have a plugin.json"
            { $manifest = Get-Content $pluginJsonPath -Raw | ConvertFrom-Json } | Should -Not -Throw -Because "$pluginName plugin.json must be valid JSON"
            $manifest = Get-Content $pluginJsonPath -Raw | ConvertFrom-Json
            $manifest.name | Should -Be $pluginName -Because "plugin.json name must match directory name"
            $manifest.version | Should -Not -BeNullOrEmpty -Because "plugin.json must declare a version"
            $manifest.description | Should -Not -BeNullOrEmpty -Because "plugin.json must declare a description"
            $manifest.skills | Should -Not -BeNullOrEmpty -Because "plugin.json must point to a skills directory"
        }
    }
}

Describe 'PluginRunbook — Runbook Frontmatter' -Tag 'PluginRunbook', 'Unit', 'Regression' {
    It 'every runbook has required frontmatter fields' {
        $script:AllRunbooks | ForEach-Object {
            $runbookPath = $_.FullName
            $parsed = Get-RunbookFrontmatter -Path $runbookPath
            $parsed | Should -Not -BeNullOrEmpty -Because "$($_.FullName) must have YAML frontmatter delimited by ---"

            Get-FrontmatterValue -Frontmatter $parsed.Frontmatter -Key 'name' | Should -Not -BeNullOrEmpty -Because "runbook must have a name"
            Get-FrontmatterValue -Frontmatter $parsed.Frontmatter -Key 'description' | Should -Not -BeNullOrEmpty -Because "runbook must have a description"
            $parsed.Frontmatter | Should -Match 'allowed-tools:' -Because "runbook must list allowed-tools"
            $parsed.Frontmatter | Should -Match 'triggers:' -Because "runbook must list triggers"
        }
    }

    It 'runbook name matches its directory name' {
        $script:AllRunbooks | ForEach-Object {
            $runbookDir = $_.Directory.Name
            $parsed = Get-RunbookFrontmatter -Path $_.FullName
            $name = Get-FrontmatterValue -Frontmatter $parsed.Frontmatter -Key 'name'
            $name | Should -Be $runbookDir -Because "runbook frontmatter name must match directory"
        }
    }

    It 'runbook Plugin line matches its plugin directory' {
        $script:AllRunbooks | ForEach-Object {
            $pluginName = $_.Directory.Parent.Parent.Name
            $parsed = Get-RunbookFrontmatter -Path $_.FullName
            $parsed.Body | Should -Match "\*\*Plugin:\*\* ``$pluginName``" -Because "runbook must declare its plugin"
        }
    }
}

Describe 'PluginRunbook — Master Runbook Routing' -Tag 'PluginRunbook', 'Unit', 'Regression' {
    It 'master runbooks only reference existing child runbooks' {
        $script:AllRunbooks | ForEach-Object {
            $parsed = Get-RunbookFrontmatter -Path $_.FullName
            $children = Get-MasterChildRunbooks -Body $parsed.Body
            if ($children.Count -gt 0) {
                $pluginDir = $_.Directory.Parent.Parent.FullName
                $children | ForEach-Object {
                    $childPath = Join-Path $pluginDir 'skills' $_ 'SKILL.md'
                    Test-Path $childPath | Should -Be $true -Because "master runbook in $($_.FullName) references missing child $_"
                }
            }
        }
    }

    It 'master runbook child names are unique within a master' {
        $script:AllRunbooks | ForEach-Object {
            $parsed = Get-RunbookFrontmatter -Path $_.FullName
            $children = Get-MasterChildRunbooks -Body $parsed.Body
            if ($children.Count -gt 0) {
                $children | Select-Object -Unique | Should -HaveCount $children.Count -Because "master runbook should not list duplicate children"
            }
        }
    }
}

Describe 'PluginRunbook — Canonical Skill References' -Tag 'PluginRunbook', 'Unit', 'Regression' {
    It 'every canonical skill path referenced by a runbook exists on disk' {
        $script:AllRunbooks | ForEach-Object {
            $parsed = Get-RunbookFrontmatter -Path $_.FullName
            $paths = Get-CanonicalSkillPaths -Body $parsed.Body
            $paths | ForEach-Object {
                $fullPath = if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $script:RepoRoot $_ }
                Test-Path $fullPath | Should -Be $true -Because "runbook references missing canonical skill $_"
            }
        }
    }

    It 'every canonical skill referenced by a runbook is registered in skills.json' {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $registeredPaths = $registry | ForEach-Object { $_.path }

        $script:AllRunbooks | ForEach-Object {
            $parsed = Get-RunbookFrontmatter -Path $_.FullName
            $paths = Get-CanonicalSkillPaths -Body $parsed.Body
            $paths | Where-Object { $_ -like 'Skills/*' } | ForEach-Object {
                $_ | Should -BeIn $registeredPaths -Because "canonical skill path $_ should be in skills.json"
            }
        }
    }
}

Describe 'PluginRunbook — Skills Plugin Mapping' -Tag 'PluginRunbook', 'Unit', 'Regression' {
    It 'every skill plugin value has a corresponding plugin directory' {
        $registry = Get-Content $script:SkillsJsonPath -Raw | ConvertFrom-Json
        $plugins = $script:AllPlugins | ForEach-Object { $_.Name }

        $registry | Where-Object { $_.plugin } | ForEach-Object {
            $_.plugin | Should -BeIn $plugins -Because "skill $($_.name) references an unknown plugin '$($_.plugin)'"
        }
    }

    It 'every plugin has at least one master runbook' {
        $script:AllPlugins | ForEach-Object {
            $pluginName = $_.Name
            $masterPath = Join-Path $_.FullName 'skills' $pluginName 'SKILL.md'
            Test-Path $masterPath | Should -Be $true -Because "plugin $pluginName must have a master runbook at skills/$pluginName/SKILL.md"
        }
    }
}
