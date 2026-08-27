#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Source: AQE pipeline schema (docs/Reference/AQE-Pipeline-Schema.md)
# ==============================================================================

BeforeAll {
    $RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $SchemaDoc = Join-Path $RepoRoot 'docs\Reference\AQE-Pipeline-Schema.md'
    Import-Module powershell-yaml -Force -ErrorAction Stop
}

Describe 'AQE Pipeline Schema documentation examples' -Tag 'Documentation' {
    It 'should contain the executable validation example' {
        $content = Get-Content $SchemaDoc -Raw
        $content | Should -Match '### Executable Validation Example'
    }

    It 'executable validation example YAML should parse as valid' {
        $content = Get-Content $SchemaDoc -Raw

        $yamlStart = $content.IndexOf('name: validate-example')
        $yamlEnd = $content.IndexOf('```', $yamlStart)
        $yamlBlock = $content.Substring($yamlStart, $yamlEnd - $yamlStart)

        $parsed = ConvertFrom-Yaml $yamlBlock -ErrorAction Stop

        $parsed.name | Should -BeExactly 'validate-example'
        $parsed.steps | Should -Not -BeNullOrEmpty
        $parsed.steps.Count | Should -BeGreaterOrEqual 4
        $parsed.steps[0].id | Should -BeExactly 'check-input'
        $parsed.steps[0].type | Should -BeExactly 'validate'
    }
}
