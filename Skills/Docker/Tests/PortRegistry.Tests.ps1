#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# ==============================================================================
# Source: Infrastructure/port-registry.json (ADR 0014)
# ==============================================================================

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $RegistryPath = Join-Path $RepoRoot "Infrastructure" "port-registry.json"
    $RegistryPath | Should -Exist
    $script:Registry = Get-Content $RegistryPath -Raw | ConvertFrom-Json
}

Describe "Port Registry Integrity" -Tag "PortRegistry", "Governance" {

    It "Internal ports have no duplicates" {
        $internalPorts = $script:Registry.internal.PSObject.Properties | ForEach-Object { $_.Value }
        $duplicates = $internalPorts | Group-Object | Where-Object Count -gt 1
        $duplicates | Should -BeNullOrEmpty
    }

    It "Host ports have no duplicates" {
        $hostPorts = $script:Registry.host.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [int]) { $_.Value }
        }
        $duplicates = $hostPorts | Group-Object | Where-Object Count -gt 1
        $duplicates | Should -BeNullOrEmpty
    }

    It "No port value is shared by different services" {
        $portMapping = @{}
        $script:Registry.internal.PSObject.Properties | ForEach-Object { $portMapping[$_.Value] = $_.Name }
        $script:Registry.host.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [int]) {
                if ($portMapping.ContainsKey($_.Value) -and $portMapping[$_.Value] -ne $_.Name) {
                    $portMapping[$_.Value] = "CONFLICT: $($portMapping[$_.Value]) vs $($_.Name)"
                } elseif (-not $portMapping.ContainsKey($_.Value)) {
                    $portMapping[$_.Value] = $_.Name
                }
            }
        }
        $conflicts = $portMapping.GetEnumerator() | Where-Object { $_.Value -like "CONFLICT:*" }
        $conflicts | Should -BeNullOrEmpty
    }

    It "All internal ports are within 21000-21999 range or upstream range" {
        $internalPorts = $script:Registry.internal.PSObject.Properties | ForEach-Object { $_.Value }
        $sidecarRange = 21000..21999
        $upstreamRange = 3000..3999
        foreach ($port in $internalPorts) {
            ($port -in $sidecarRange -or $port -in $upstreamRange) | Should -Be $true -Because "port $port should be in sidecar (21000-21999) or upstream (3000-3999) range"
        }
    }

    It "Gateway role specs were retired (host.gateway removed 2026-08-21)" {
        # The gateway host port ranges and agent role blocks (base/orch/veri/work)
        # were retired with the openclaw agent layer. Assert they are absent.
        $script:Registry.host.PSObject.Properties.Name | Should -Not -Contain 'gateway'
    }

    It "Firewall range covers all host ports" {
        $hostPorts = $script:Registry.host.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [int]) { $_.Value }
        }
        $rangeStart = $script:Registry.ranges.gateway_host_ports.start
        $rangeEnd   = $script:Registry.ranges.gateway_host_ports.end
        foreach ($port in $hostPorts) {
            $port -ge $rangeStart | Should -Be $true -Because "host port $port should be >= $rangeStart"
            $port -le $rangeEnd | Should -Be $true -Because "host port $port should be <= $rangeEnd"
        }
    }

    It "Retired ports are excluded from internal and host" {
        if ($script:Registry.retired.PSObject.Properties.Count -eq 0) {
            Set-ItResult -Skipped -Because "No retired ports defined"
            return
        }
        $retiredPorts = $script:Registry.retired.PSObject.Properties | ForEach-Object { $_.Value }
        $internalPorts = $script:Registry.internal.PSObject.Properties | ForEach-Object { $_.Value }
        $hostPorts = $script:Registry.host.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [int]) { $_.Value }
        }
        $activePorts = $internalPorts + $hostPorts
        $orphaned = $retiredPorts | Where-Object { $_ -in $activePorts }
        $orphaned | Should -BeNullOrEmpty
    }
}

Describe "Port Registry — SalmonRun.Core Integration" -Tag "PortRegistry", "Core" {

    It "Get-ServicePort resolves all internal services" {
        . (Join-Path $RepoRoot "Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1")
        $services = $script:Registry.internal.PSObject.Properties.Name
        $sidecarRange = 21000..21999
        $upstreamRange = 3000..3999
        foreach ($svc in $services) {
            $port = Get-ServicePort -Service $svc -Type internal
            $port | Should -Not -BeNullOrEmpty
            ($port -in $sidecarRange -or $port -in $upstreamRange) | Should -Be $true -Because "port $port should be in sidecar (21000-21999) or upstream (3000-3999) range"
        }
    }

    It "Get-InterclawConstants port values match registry" -Skip {
        . (Join-Path $RepoRoot "Orchestrator\Modules\SalmonRun.Constants\SalmonRun.Constants.ps1")
        $constants = $script:InterclawConstants
        $constants.FleetApiPort | Should -Be (Get-ServicePort -Service is-fleet)
        # mcp_opencode_server, is-api, mcp_aqe, mcp_web retired 2026-08-21
    }
}

Describe "Port Registry — glossary is-marketer port agreement" -Tag "Deploy", "Regression-Only" {
    BeforeAll {
        $GlossaryPath = Join-Path $RepoRoot "docs" "Glossaries" "infrastructure.md"
        $GlossaryPath | Should -Exist
        $script:GlossaryContent = Get-Content $GlossaryPath -Raw
        $script:RegistryPorts = @()
        $script:Registry.internal.PSObject.Properties | ForEach-Object { $script:RegistryPorts += [int]$_.Value }
        $script:Registry.host.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [int] -or $_.Value -is [long]) { $script:RegistryPorts += [int]$_.Value }
        }
        $script:Registry.retired.PSObject.Properties | ForEach-Object { $script:RegistryPorts += [int]$_.Name }
    }

    It "is-marketer entry lists port 21011, not 21014" {
        $isMarketerBlock = [regex]::Match($script:GlossaryContent, '(?ms)^\*\*is-marketer\*\*:.*?^_Source_:.*?$')
        $isMarketerBlock.Success | Should -Be $true -Because "the is-marketer glossary entry should be present"
        $isMarketerBlock.Value | Should -Match '21011'
        $isMarketerBlock.Value | Should -Not -Match '21014'
    }

    It "no 21014 remains outside the changelog" {
        $beforeChangelog = $script:GlossaryContent -split "## Changelog" | Select-Object -First 1
        [regex]::Matches($beforeChangelog, '21014').Count | Should -Be 0 -Because "any 21014 occurrence outside the changelog must have been corrected to the registry value"
    }

    It "every 21xxx port claimed in the glossary files resolves in the registry" {
        $glossaryFiles = @(
            (Join-Path $RepoRoot "docs" "Glossaries" "infrastructure.md"),
            (Join-Path $RepoRoot "docs" "Glossaries" "agent-operations.md"),
            (Join-Path $RepoRoot "docs" "Glossaries" "deployment.md"),
            (Join-Path $RepoRoot "docs" "Glossaries" "_shared.md")
        )
        $unresolved = @()
        foreach ($gFile in $glossaryFiles) {
            if (-not (Test-Path $gFile)) { continue }
            $lines = Get-Content $gFile
            for ($i = 0; $i -lt $lines.Count; $i++) {
                foreach ($m in [regex]::Matches($lines[$i], '(?<![\d-])21\d{3}(?![\d-])')) {
                    $port = [int]$m.Value
                    if ($port -notin $script:RegistryPorts) {
                        $unresolved += "$([IO.Path]::GetFileName($gFile)):$($i + 1) port $port"
                    }
                }
            }
        }
        $unresolved | Should -BeNullOrEmpty -Because "every glossary port claim must resolve in port-registry.json (internal, host, or retired)"
    }
}