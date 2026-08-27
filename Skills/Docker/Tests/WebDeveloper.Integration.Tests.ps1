#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:SkillsJson = Get-Content (Join-Path $PSScriptRoot '..\..\..\Skills\skills.json') -Raw | ConvertFrom-Json
    $script:SkillsIndex = Get-Content (Join-Path $PSScriptRoot '..\..\..\Skills\skills-index.json') -Raw | ConvertFrom-Json
    $script:IndexEntry = $script:SkillsIndex.PSObject.Properties.Where({ $_.Name -eq 'web-developer' }).Value
    $script:Templates = @('guide', 'estimate', 'status')
}

Describe 'WebDeveloper skill registration' -Tag 'WebDeveloper', 'Unit' {
    It 'is registered in skills.json' {
        $entry = $script:SkillsJson | Where-Object { $_.name -eq 'web-developer' }
        $entry | Should -Not -BeNullOrEmpty
    }

    It 'has correct container type in skills.json' {
        $entry = $script:SkillsJson | Where-Object { $_.name -eq 'web-developer' }
        $entry.container | Should -Be 'opencode'
        $entry.type | Should -Be 'skill'
    }

    It 'is registered in skills-index.json' {
        $script:IndexEntry | Should -Not -BeNullOrEmpty
    }

    It 'has matching path in both registries' {
        $jsonPath = ($script:SkillsJson | Where-Object { $_.name -eq 'web-developer' }).path
        $indexPath = $script:IndexEntry.path
        $jsonPath | Should -Be $indexPath
    }

    It 'skill entrypoint file exists on disk' {
        $entry = $script:SkillsJson | Where-Object { $_.name -eq 'web-developer' }
        $entry.path | Should -Exist
    }

    It 'Invoke-HtmlReport.ps1 exists' {
        (Join-Path $PSScriptRoot '..\..\..\Skills\WebDeveloper\Invoke-HtmlReport.ps1') | Should -Exist
    }
}

Describe 'WebDeveloper templates' -Tag 'WebDeveloper', 'Unit' {
    It "has all three templates present" {
        foreach ($tpl in $script:Templates) {
            $path = Join-Path $PSScriptRoot "..\..\..\Skills\WebDeveloper\templates\$tpl.html.tmpl"
            $path | Should -Exist -Because "template $tpl.html.tmpl should exist"
        }
    }

    It "each template contains required sections" {
        foreach ($tpl in $script:Templates) {
            $path = Join-Path $PSScriptRoot "..\..\..\Skills\WebDeveloper\templates\$tpl.html.tmpl"
            $content = Get-Content $path -Raw
            $content | Should -Match '<!DOCTYPE html>'
            $content | Should -Match '</html>'
        }
    }

    It "each template has inline CSS" {
        foreach ($tpl in $script:Templates) {
            $path = Join-Path $PSScriptRoot "..\..\..\Skills\WebDeveloper\templates\$tpl.html.tmpl"
            $content = Get-Content $path -Raw
            $content | Should -Match '<style>'
            $content | Should -Not -Match '<link rel="stylesheet"'
        }
    }
}
