#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

Describe 'Sync-FromCanonical.ps1' {
    It 'requires a canonical repo parameter or env var' {
        $script = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Sync-FromCanonical.ps1'
        { & $script -WhatIf } | Should -Throw '*Provide -CanonicalRepo or set SALMON_CANONICAL_REPO*'
    }

    It 'copies and scrubs a canonical tree' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path $TestDrive "sync-$(Get-Random)") -Force
        $canonical = Join-Path $tmp 'canonical'
        $public = Join-Path $tmp 'public'
        $srcModules = Join-Path $canonical 'Orchestrator/Modules/SalmonRun.Test'
        $srcSkills = Join-Path $canonical 'Skills/SalmonRun.TestSkill'
        $null = New-Item -ItemType Directory -Path $srcModules -Force
        $null = New-Item -ItemType Directory -Path $srcSkills -Force

        $profilePath = $env:USERPROFILE
        "Write-Host `"private $profilePath path`"" | Set-Content -LiteralPath (Join-Path $srcModules 'Test.ps1') -Encoding utf8
        'api_key=abc123' | Set-Content -LiteralPath (Join-Path $srcSkills 'config.json') -Encoding utf8

        $script = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Sync-FromCanonical.ps1'
        & $script -CanonicalRepo $canonical -PublicRepo $public -SkipLeakCheck

        $dstModules = Join-Path $public 'Orchestrator/Modules/SalmonRun.Test'
        $dstSkills = Join-Path $public 'Skills/SalmonRun.TestSkill'
        $dstModules | Should -Exist
        $dstSkills | Should -Exist

        $ps1 = Get-Content -LiteralPath (Join-Path $dstModules 'Test.ps1') -Raw
        $ps1 | Should -Not -Match 'C:\\\+Users\\\\+'
        $ps1 | Should -Match '{{REDACTED}}'

        $json = Get-Content -LiteralPath (Join-Path $dstSkills 'config.json') -Raw
        $json | Should -Not -Match 'abc123'
        $json | Should -Match '{{REDACTED}}'
    }

    It 'supports -WhatIf without writing files' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path $TestDrive "sync-whatif-$(Get-Random)") -Force
        $canonical = Join-Path $tmp 'canonical'
        $public = Join-Path $tmp 'public'
        $srcModules = Join-Path $canonical 'Orchestrator/Modules/SalmonRun.Test'
        $null = New-Item -ItemType Directory -Path $srcModules -Force
        '1' | Set-Content -LiteralPath (Join-Path $srcModules 'Test.ps1') -Encoding utf8

        $script = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Sync-FromCanonical.ps1'
        & $script -CanonicalRepo $canonical -PublicRepo $public -SkipLeakCheck -WhatIf

        $public | Should -Not -Exist
    }
}
