#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

Describe 'public-to-private canonical synchronization' -Tag 'Sync', 'Regression-Only' {
    BeforeEach {
        $script:Fixture = New-Item -ItemType Directory -Path (Join-Path $TestDrive "sync-$(Get-Random)") -Force
        $script:Public = New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'public') -Force
        $script:Private = New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'private') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Public 'Modules/Core') -Force
        'canonical' | Set-Content -LiteralPath (Join-Path $script:Public 'Modules/Core/core.ps1') -NoNewline
        'private extension' | Set-Content -LiteralPath (Join-Path $script:Private 'deployment-extension.ps1') -NoNewline
        $script:Manifest = Join-Path $script:Fixture 'manifest.json'
        @{ schemaVersion=1; direction='public-to-private'; entries=@(@{source='Modules/Core';target='Orchestrator/Modules/Core'}); protectedPrivatePaths=@('Tasks','docs','Plugins','.env') } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Manifest -NoNewline
        $script:Sync = Join-Path $PSScriptRoot '..' 'scripts' 'Sync-ToPrivate.ps1'
        $script:Parity = Join-Path $PSScriptRoot '..' 'scripts' 'Test-PrivateParity.ps1'
    }

    It 'retires the private-to-public projection contract' {
        $legacy = Join-Path $PSScriptRoot '..' 'scripts' 'Sync-FromCanonical.ps1'
        { & $legacy } | Should -Throw '*Public salmon-run is canonical*'
    }

    It 'copies only manifest entries and preserves deployment-specific private files' {
        $output = & $script:Sync -PublicRepo $script:Public -PrivateRepo $script:Private -ManifestPath $script:Manifest -Verify
        (Join-Path $script:Private 'Orchestrator/Modules/Core/core.ps1') | Should -Exist
        (Get-Content (Join-Path $script:Private 'Orchestrator/Modules/Core/core.ps1') -Raw) | Should -Be 'canonical'
        (Join-Path $script:Private 'deployment-extension.ps1') | Should -Exist
        $output | Should -Contain 'SALMON_PRIVATE_PARITY_PASS'
        $output | Should -Contain 'SALMON_PUBLIC_TO_PRIVATE_SYNC_PASS'
    }

    It 'fails parity when a private copy drifts' {
        & $script:Sync -PublicRepo $script:Public -PrivateRepo $script:Private -ManifestPath $script:Manifest | Out-Null
        'drifted' | Set-Content -LiteralPath (Join-Path $script:Private 'Orchestrator/Modules/Core/core.ps1') -NoNewline
        { & $script:Parity -PublicRepo $script:Public -PrivateRepo $script:Private -ManifestPath $script:Manifest } | Should -Throw '*drift*'
    }

    It 'rejects manifest targets in protected private paths' {
        @{ schemaVersion=1; direction='public-to-private'; entries=@(@{source='Modules/Core';target='Tasks/Core'}); protectedPrivatePaths=@('Tasks') } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Manifest -NoNewline
        { & $script:Sync -PublicRepo $script:Public -PrivateRepo $script:Private -ManifestPath $script:Manifest } | Should -Throw '*protected private state*'
    }
}
