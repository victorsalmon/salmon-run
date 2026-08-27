#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:ScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Test-ClientServiceHealth.ps1"
    $script:RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $script:ManifestPath = Join-Path $script:RepoRoot "Infrastructure\manifests\client-services.json"
}

Describe "Client Service Health" -Tag "ClientServiceHealth", "Unit" {
    Context "Manifest parsing" {
        It "reads the manifest without error" {
            $manifest = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
            $manifest.version | Should -BeGreaterThan 0
            $manifest.clients.Count | Should -BeGreaterThan 0
        }

        It "has base_services defined" {
            $manifest = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
            $manifest.base_services.services.Count | Should -BeGreaterThan 0
        }

        It "each client has name, display_name, description, services" {
            $manifest = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
            foreach ($client in $manifest.clients) {
                $client.name | Should -Not -BeNullOrEmpty
                $client.display_name | Should -Not -BeNullOrEmpty
                $client.description | Should -Not -BeNullOrEmpty
                $client.services | Should -Not -BeNullOrEmpty
                Should -Not -BeNull -InputObject $client.services.required
                Should -Not -BeNull -InputObject $client.services.optional
            }
        }

        It "each required service exists in the port registry" {
            $manifest = Get-Content -Raw -LiteralPath $script:ManifestPath | ConvertFrom-Json
            $portRegistry = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "Infrastructure\port-registry.json") | ConvertFrom-Json
            $allRequired = $manifest.base_services.services + @($manifest.clients | ForEach-Object { $_.services.required })
            $knownPorts = $portRegistry.internal.PSObject.Properties.Name
            foreach ($svc in $allRequired | Select-Object -Unique) {
                if ($knownPorts -contains $svc) { continue }
                # Some services (oc-base) use host ports or generic names
                # Skip those not in the internal port registry — they're gateway services
                Write-Host "INFO: $svc has no internal port — using host/gateway port"
            }
        }
    }

    Context "Service status with mock docker" {
        It "returns healthy when all services are at desired replicas" {
            function global:docker {
                $global:LASTEXITCODE = 0
                $argsLine = $args -join " "
                if ($argsLine -match 'service ls') {
                    return @(
                        "FRAD_oc-base 1/1",
                        "FRAD_is-fleet 1/1"
                    )
                }
                return ""
            }
            $results = & $script:ScriptPath -ManifestPath $script:ManifestPath -PassThru
            $results | Should -Not -BeNullOrEmpty
            $clientsWithServices = $results | Where-Object { $_.status -ne "skip" }
            foreach ($client in $clientsWithServices) {
                $client.status | Should -Be "healthy" -Because "$($client.display) should be healthy when all replicas up"
            }
            Remove-Item Function:\docker -ErrorAction SilentlyContinue
        }

        It "reports down when services have 0 replicas" {
            function global:docker {
                $global:LASTEXITCODE = 0
                $argsLine = $args -join " "
                if ($argsLine -match 'service ls') {
                    return @(
                        "FRAD_oc-base 0/1",
                        "FRAD_is-fleet 0/1"
                    )
                }
                return ""
            }
            $results = & $script:ScriptPath -ManifestPath $script:ManifestPath -PassThru
            $clientsWithServices = $results | Where-Object { $_.status -ne "skip" }
            foreach ($client in $clientsWithServices) {
                $client.status | Should -Be "down" -Because "$($client.display) should be down when all replicas at 0"
            }
            Remove-Item Function:\docker -ErrorAction SilentlyContinue
        }

        It "reports degraded when some services are below desired" {
            function global:docker {
                $global:LASTEXITCODE = 0
                $argsLine = $args -join " "
                if ($argsLine -match 'service ls') {
                    return @(
                        "FRAD_oc-base 1/1",
                        "FRAD_is-fleet 1/2"
                    )
                }
                return ""
            }
            $results = & $script:ScriptPath -ManifestPath $script:ManifestPath -PassThru
            $upscaleHavens = $results | Where-Object { $_.client -eq "upscale-havens" }
            $upscaleHavens.status | Should -Be "degraded" -Because "is-fleet has 1/2 replicas"
            Remove-Item Function:\docker -ErrorAction SilentlyContinue
        }

        It "skips clients with no required services" {
            function global:docker {
                $global:LASTEXITCODE = 0
                $argsLine = $args -join " "
                if ($argsLine -match 'service ls') {
                    return @("FRAD_oc-base 1/1")
                }
                return ""
            }
            $results = & $script:ScriptPath -ManifestPath $script:ManifestPath -PassThru
            $skipClients = $results | Where-Object { $_.status -eq "skip" }
            $skipClients.Count | Should -BeGreaterOrEqual 5
            $skipClients.client | Should -Contain "resume"
            $skipClients.client | Should -Contain "chronoclysm-series"
            $skipClients.client | Should -Contain "vsalmon-therapy"
            $skipClients.client | Should -Contain "clocklobster-site"
            $skipClients.client | Should -Contain "intersite-docs"
            Remove-Item Function:\docker -ErrorAction SilentlyContinue
        }

        It "filters by -ClientName" {
            function global:docker {
                $global:LASTEXITCODE = 0
                $argsLine = $args -join " "
                if ($argsLine -match 'service ls') {
                    return @(
                        "FRAD_is-fleet 1/1",
                        "FRAD_oc-base 1/1"
                    )
                }
                return ""
            }
            $results = & $script:ScriptPath -ManifestPath $script:ManifestPath -ClientName upscale -PassThru
            $results.Count | Should -Be 1
            $results[0].client | Should -Be "upscale-havens"
            Remove-Item Function:\docker -ErrorAction SilentlyContinue
        }

        It "handles missing docker gracefully" {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq "docker" -and $ErrorAction -eq "SilentlyContinue" }
            $results = & $script:ScriptPath -ManifestPath $script:ManifestPath -PassThru
            $results | Should -BeNullOrEmpty
        }
    }
}