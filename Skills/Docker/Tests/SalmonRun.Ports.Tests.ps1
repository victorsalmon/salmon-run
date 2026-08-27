#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $PortsModuleDir = Join-Path $RepoRoot "Skills" "Docker" "Modules" "SalmonRun.Ports"
    $PortsPsd1 = Join-Path $PortsModuleDir "SalmonRun.Ports.psd1"
    $PortsPsd1 | Should -Exist
    $RegistryPath = Join-Path $RepoRoot "port-registry.json"
    $RegistryPath | Should -Exist
    $script:Registry = Get-Content $RegistryPath -Raw | ConvertFrom-Json

    $diagnosticsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
    if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
    $pathsPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
    if (Test-Path $pathsPath) { . $pathsPath }

    . (Join-Path $PortsModuleDir "SalmonRun.Ports.ps1")
}

Describe "Get-PortRegistry" -Tag "Ports", "PortRegistry" {

    BeforeEach {
        InModuleScope SalmonRun.Ports { $script:PortRegistryCache = $null }
    }

    It "loads the registry as a PSCustomObject" {
        $reg = Get-PortRegistry
        $reg | Should -Not -BeNullOrEmpty
        $reg.internal | Should -Not -BeNullOrEmpty
        $reg.host | Should -Not -BeNullOrEmpty
    }

    It "returns a hashtable-compatible object with version property" {
        $reg = Get-PortRegistry
        $reg.version | Should -Be "2.0"
    }

    It "returns cached result on repeated calls" {
        $first = Get-PortRegistry
        $second = Get-PortRegistry
        $first.GetHashCode() | Should -Be $second.GetHashCode()
    }

    It "returns null when file is missing" {
        $originalPath = Join-Path $RepoRoot "port-registry.json"
        $backupPath = Join-Path $RepoRoot "port-registry.json.bak"
        try {
            if (Test-Path $originalPath) {
                Rename-Item $originalPath $backupPath
            }
            InModuleScope SalmonRun.Ports { $script:PortRegistryCache = $null }
            $result = Get-PortRegistry
            $result | Should -BeNullOrEmpty
        } finally {
            if ((Test-Path $backupPath) -and -not (Test-Path $originalPath)) {
                Rename-Item $backupPath $originalPath
            }
        }
    }
}

Describe "Get-ServicePort" -Tag "Ports", "PortRegistry" {

    It "resolves internal port for every service in registry" {
        $services = $script:Registry.internal.PSObject.Properties.Name
        $sidecarRange = 21000..21999
        $upstreamRange = 3000..3999
        foreach ($svc in $services) {
            $port = Get-ServicePort -Service $svc -Type internal
            $port | Should -Not -BeNullOrEmpty
            ($port -in $sidecarRange -or $port -in $upstreamRange) | Should -Be $true -Because "port $port should be in sidecar (21000-21999) or upstream (3000-3999) range"
        }
    }

    It "resolves host port for is-fleet" {
        $port = Get-ServicePort -Service is-fleet -Type host
        $port | Should -Be 29999
    }

    It "throws for unknown service" {
        { Get-ServicePort -Service does-not-exist -Type internal } | Should -Throw
    }

    It "falls back to defaults when registry is null" {
        $originalPath = Join-Path $RepoRoot "port-registry.json"
        $backupPath = Join-Path $RepoRoot "port-registry.json.bak"
        try {
            if (Test-Path $originalPath) {
                Rename-Item $originalPath $backupPath
            }
            InModuleScope SalmonRun.Ports { $script:PortRegistryCache = $null }
            $port = Get-ServicePort -Service is-fleet -Type internal
            $port | Should -Be 21002
        } finally {
            if ((Test-Path $backupPath) -and -not (Test-Path $originalPath)) {
                Rename-Item $backupPath $originalPath
            }
        }
    }
}

Describe "Port Registry Governance" -Tag "Ports", "Regression-Only", "PortRegistry" {

    It "all internal services have both internal and host port entries" {
        $internalServices = $script:Registry.internal.PSObject.Properties.Name
        $hostServices = $script:Registry.host.PSObject.Properties.Name
        $internalServices | Should -Not -Be $null
        $hostServices | Should -Not -Be $null
    }

    It "no duplicate internal ports" {
        $internalPorts = $script:Registry.internal.PSObject.Properties | ForEach-Object { $_.Value }
        $duplicates = $internalPorts | Group-Object | Where-Object Count -gt 1
        $duplicates | Should -BeNullOrEmpty
    }

    It "no duplicate host ports" {
        $hostPorts = $script:Registry.host.PSObject.Properties | ForEach-Object {
            if ($_.Value -is [int]) { $_.Value }
        }
        $duplicates = $hostPorts | Group-Object | Where-Object Count -gt 1
        $duplicates | Should -BeNullOrEmpty
    }

    It "no port value is shared by different services" {
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

    It "all internal ports within 21000-21999 range or upstream range" {
        $internalPorts = $script:Registry.internal.PSObject.Properties | ForEach-Object { $_.Value }
        $sidecarRange = 21000..21999
        $upstreamRange = 3000..3999
        foreach ($port in $internalPorts) {
            ($port -in $sidecarRange -or $port -in $upstreamRange) | Should -Be $true -Because "port $port should be in sidecar (21000-21999) or upstream (3000-3999) range"
        }
    }
}
