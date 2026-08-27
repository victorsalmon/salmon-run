#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Domain9 Invariant 4 — Stable Compose Generation" -Tag "Deploy", "Regression-Only" {
    BeforeAll {
        $deployDir = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public"
        $composePath = Join-Path $deployDir "New-FleetCompose.ps1"
        $builderFiles = @(
            Join-Path $deployDir "Add-AgentServiceToCompose.ps1"
            Join-Path $deployDir "Add-FleetServiceToCompose.ps1"
            Join-Path $deployDir "Add-SidecarServicesToCompose.ps1"
        )
        $content = ($builderFiles | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
    }

    It "all interclaw.created-at labels use {{.CreatedAt}} Docker template" {
        $timestamps = [regex]::Matches($content, 'interclaw\.created-at')
        $timestamps.Count | Should -BeGreaterThan 0
        $dateCalls = [regex]::Matches($content, 'interclaw\.created-at.*Get-Date')
        $dateCalls.Count | Should -Be 0
    }

    It "INTERCLAW_CREATED_AT env var was removed (not supported in Docker env templates)" {
        $content | Should -Not -Match 'INTERCLAW_CREATED_AT'
    }

    It "no (Get-Date -Format 'o') calls remain in label definitions" {
        $labelsWithGetDate = [regex]::Matches($content, '"interclaw\.[a-z-]+".*=.*Get-Date')
        $labelsWithGetDate.Count | Should -Be 0
    }

    It "New-FleetCompose can be sourced without errors" {
        { . $composePath } | Should -Not -Throw
    }

    It "New-FleetCompose produces deterministic output (idempotent — same inputs, same YAML)" -Tag "Regression" {
        . $composePath

        $agent3 = @(
            @{ Role='BASE'; Index=0; InstanceId='84'; AgentName='Agent-TST-BASE-84'; GatewayPort=20300 }
            @{ Role='BASE'; Index=1; InstanceId='85'; AgentName='Agent-TST-BASE-85'; GatewayPort=20301 }
            @{ Role='BASE'; Index=2; InstanceId='86'; AgentName='Agent-TST-BASE-86'; GatewayPort=20302 }
        )
        $run1Dir = Join-Path $env:TEMP "Interclaw-Idempotent-Run1-$(Get-Random)"
        $run2Dir = Join-Path $env:TEMP "Interclaw-Idempotent-Run2-$(Get-Random)"
        New-Item -ItemType Directory -Path $run1Dir -Force | Out-Null
        New-Item -ItemType Directory -Path $run2Dir -Force | Out-Null

        try {
            $path1 = Join-Path $run1Dir "compose.yml"
            $path2 = Join-Path $run2Dir "compose.yml"

            New-FleetCompose -Agents $agent3 -ProjectCode 'TST' -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path1 -SovereigntyTier 'canada'
            New-FleetCompose -Agents $agent3 -ProjectCode 'TST' -InstallTailscale 'false' -InstallFleet 'false' -OutputPath $path2 -SovereigntyTier 'canada'

            $hash1 = (Get-FileHash -Path $path1 -Algorithm SHA256).Hash
            $hash2 = (Get-FileHash -Path $path2 -Algorithm SHA256).Hash
            $hash1 | Should -BeExactly $hash2
        } finally {
            if (Test-Path $run1Dir) { Remove-Item -Recurse -Force $run1Dir }
            if (Test-Path $run2Dir) { Remove-Item -Recurse -Force $run2Dir }
        }
    }

    It "Initialize-AgentVolumes is idempotent by design (skips existing volumes)" {
        $volPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Deploy\Public\Initialize-AgentVolumes.ps1"
        $volContent = Get-Content -LiteralPath $volPath -Raw
        $volContent | Should -Match 'docker volume ls.*-q.*-f.*name='
        $volContent | Should -Match 'SKIP.*Volume already exists'
    }
}
