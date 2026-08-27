#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $PortRegPath = Join-Path $RepoRoot "Infrastructure" "port-registry.json"
    $EnvVarRegPath = Join-Path $RepoRoot "docs" "Reference" "env-var-registry.json"
    $BundlePath = Join-Path $RepoRoot "Skills" "Docker" "Modules" "SalmonRun.Secrets" "Private" "bundle-manifest.ps1"

    $PortRegPath | Should -Exist
    $EnvVarRegPath | Should -Exist
    $BundlePath | Should -Exist

    $script:PortReg = Get-Content $PortRegPath -Raw | ConvertFrom-Json
    $script:EnvVarReg = Get-Content $EnvVarRegPath -Raw | ConvertFrom-Json
    $script:BundleContent = Get-Content $BundlePath -Raw
    $scriptBlock = [ScriptBlock]::Create($script:BundleContent)
    . $scriptBlock

    $script:EnvVarNames = @($script:EnvVarReg.envVars.PSObject.Properties.Name)
}

Describe "Registry Consistency — env-var-registry has all bundle SourceKeys" -Tag "RegistryConsistency", "Governance" {
    It "every bundle SourceKey exists in env-var-registry" {
        $allSourceKeys = @()
        foreach ($bt in $script:BundleManifest.Keys) {
            $bundle = $script:BundleManifest[$bt]
            if ($bundle.SourceKeys) { $allSourceKeys += $bundle.SourceKeys }
        }
        $allSourceKeys = $allSourceKeys | Sort-Object -Unique
        $missing = $allSourceKeys | Where-Object { $script:EnvVarNames -notcontains $_ }
        $missing | Should -BeNullOrEmpty -Because "SourceKeys not in env-var-registry: $($missing -join ', ')"
    }
}

Describe "Registry Consistency — every EnvMap target exists in env-var-registry" -Tag "RegistryConsistency", "Governance" {
    It "all EnvMap target env vars are registered" {
        $allEnvMapTargets = @()
        foreach ($bt in $script:BundleManifest.Keys) {
            $bundle = $script:BundleManifest[$bt]
            if ($bundle.EnvMap) { $allEnvMapTargets += $bundle.EnvMap.Values }
        }
        $allEnvMapTargets = $allEnvMapTargets | Sort-Object -Unique
        $missing = $allEnvMapTargets | Where-Object { $script:EnvVarNames -notcontains $_ }
        $missing | Should -BeNullOrEmpty -Because "EnvMap targets not in env-var-registry: $($missing -join ', ')"
    }
}

Describe "Registry Consistency — bundle-manifest FleetApiTokens have env-var entries" -Tag "RegistryConsistency", "Governance" {
    It "all FleetApiToken service tokens are registered" {
        $ft = $script:BundleManifest.FleetApiTokens
        if (-not $ft) { Set-ItResult -Skipped -Because "FleetApiTokens not defined"; return }
        $allTokens = @()
        if ($ft.ServiceTokens) {
            $allTokens += [string[]]@($ft.ServiceTokens.Values)
        }
        if ($ft.MonitorTokens) {
            $allTokens += [string[]]@($ft.MonitorTokens.Values)
        }
        $allTokens = $allTokens | Sort-Object -Unique
        $missing = $allTokens | Where-Object { $script:EnvVarNames -notcontains $_ }
        $missing | Should -BeNullOrEmpty -Because "FleetApiTokens not in env-var-registry: $($missing -join ', ')"
    }
}

Describe "Registry Consistency — port-registry retired ports not in env-var-registry as active" -Tag "RegistryConsistency", "Governance" {
    It "no retired port name conflicts with active env vars" {
        if (-not $script:PortReg.retired) { Set-ItResult -Skipped -Because "No retired ports"; return }
        foreach ($rp in $script:PortReg.retired.PSObject.Properties) {
            $evName = "PORT_RETIRED_$($rp.Name)" -replace '-', '_'
            $matches = $script:EnvVarNames | Where-Object { $_ -like "*$($rp.Name)*" }
            $conflicts = $matches | Where-Object { $_ -notlike '*RETIRED*' -and $_ -notlike '*DEPRECATED*' -and $_ -notlike '*_retired_*' }
            $conflicts | Should -BeNullOrEmpty -Because "retired port $($rp.Name) has non-retired env-var match: $($conflicts -join ', ')"
        }
    }
}

Describe "Registry Consistency — optional keys not in SourceKeys are documented" -Tag "RegistryConsistency", "Governance" {
    It "optional keys missing from SourceKeys are documented as intentional" {
        $intentional = @('fleet_aws_id', 'fleet_aws_secret', 'proxy_aws_id', 'proxy_aws_secret', 'store_api_key')
        foreach ($bt in $script:BundleManifest.Keys) {
            $bundle = $script:BundleManifest[$bt]
            if ($bundle.Optional -and $bundle.SourceKeys) {
                $unreferenced = $bundle.Optional | Where-Object { $bundle.SourceKeys -notcontains $_ -and $intentional -notcontains $_ }
                $unreferenced | Should -BeNullOrEmpty -Because "bundle '$bt' has optional keys not in SourceKeys and not in intentional list: $($unreferenced -join ', ')"
            }
        }
    }
}
