#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Interclaw — Pester 5 Tests for is-marketer Container Image
# ==============================================================================

Describe "Marketer Image" -Tag "Marketer", "Regression" {

    It "marketer.Dockerfile exists and references node:20-slim + pwsh" {
        $DfPath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\marketer.Dockerfile"
        $DfPath | Should -Exist
        $df = Get-Content $DfPath -Raw
        $df | Should -Match "node:20-slim"
        $df | Should -Match "pwsh"
    }

    It "Invoke-MarketerImageBuild.ps1 exists and uses source-hash label" {
        $BuildFn = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Images\Public\Invoke-MarketerImageBuild.ps1"
        $BuildFn | Should -Exist
        $content = Get-Content $BuildFn -Raw
        $content | Should -Match "org.SalmonRun.Marketer.source-hash"
    }

    It "Invoke-MarketerImageBuild is exported in SalmonRun.Images.psd1" {
        $ManifestPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Images\SalmonRun.Images.psd1"
        $ManifestPath | Should -Exist
        $content = Get-Content $ManifestPath -Raw
        $content | Should -Match "Invoke-MarketerImageBuild"
    }

    It "Start-ParallelImageBuild.ps1 has is-marketer job" {
        $JobPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Images\Public\Start-ParallelImageBuild.ps1"
        $JobPath | Should -Exist
        $content = Get-Content $JobPath -Raw
        $content | Should -Match "is-marketer"
    }

    It "port-registry.json has is-marketer in retired section (retired 2026-08-21)" {
        $RegistryPath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\port-registry.json"
        $RegistryPath | Should -Exist
        $content = Get-Content $RegistryPath -Raw | ConvertFrom-Json
        # is-marketer was retired; its port (21011) should be in the retired section
        $content.retired.PSObject.Properties.Name | Should -Contain '21011'
        # is-marketer should NOT be in the internal section
        $content.internal.PSObject.Properties.Name | Should -Not -Contain 'is-marketer'
    }

    It "SalmonRun.Ports.psm1 has is-marketer port default" {
        $PortsPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Ports\SalmonRun.Ports.psm1"
        $PortsPath | Should -Exist
        $content = Get-Content $PortsPath -Raw
        $content | Should -Match '"is-marketer"'
    }

    It "SalmonRun.Constants.psm1 exports MarketerPort" {
        $ConstPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Constants\SalmonRun.Constants.psm1"
        $ConstPath | Should -Exist
        $content = Get-Content $ConstPath -Raw
        $content | Should -Match "MarketerPort"
    }

    It "docker-compose.interclaw.yml does NOT have is-marketer service (retired 2026-08-21)" {
        $ComposePath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\docker-compose.interclaw.yml"
        if (-not (Test-Path $ComposePath)) {
            Set-ItResult -Skipped -Because "generated compose not present in checkout; run New-FleetCompose or deploy"
            return
        }
        $content = Get-Content $ComposePath -Raw
        $content | Should -Not -Match "is-marketer:" -Because "is-marketer was retired and must not appear in generated compose"
    }

    It "Add-SidecarServicesToCompose.ps1 has programmatic marketer generation" {
        $SvcPath = Join-Path $PSScriptRoot "..\..\Modules\SalmonRun.Deploy\Public\Add-SidecarServicesToCompose.ps1"
        $SvcPath | Should -Exist
        $content = Get-Content $SvcPath -Raw
        $content | Should -Match "InstallMarketer"
    }

    It "marketer server.js exists and has invokePwshHandler" {
        $ServerPath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\marketer\server.js"
        $ServerPath | Should -Exist
        $content = Get-Content $ServerPath -Raw
        $content | Should -Match "invokePwshHandler"
    }

    It "marketer server.js has 5 standard endpoints" {
        $ServerPath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\marketer\server.js"
        $content = Get-Content $ServerPath -Raw
        $content | Should -Match "/api/health"
        $content | Should -Match "/api/ready"
        $content | Should -Match "/api/credentials"
        $content | Should -Match "/api/routes"
        $content | Should -Match "/api/version"
    }

    It "invoke-handler.ps1 imports SalmonRun.Marketer module" {
        $HandlerPath = Join-Path $PSScriptRoot "..\..\..\Infrastructure\marketer\invoke-handler.ps1"
        $HandlerPath | Should -Exist
        $content = Get-Content $HandlerPath -Raw
        $content | Should -Match "SalmonRun.Marketer"
    }
}
