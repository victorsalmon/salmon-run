#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:moduleRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName

    # Define stub functions for dependencies (Core module has pre-existing parse errors)
    function Write-SetupLog { }
    function Write-Host { }
    function Get-ImageSourceHash { return "testhash123" }
    function Get-ReportsDir { return "TestDrive:\reports" }
    function Get-InterclawConstants { return @{ PostCleanupWaitSec = 0; HealthCheckMaxRetries = 1; HealthCheckRetryIntervalSec = 1 } }
    function Invoke-DockerWithLogging { return [PSCustomObject]@{ Success = $true; ExitCode = 0; Output = "" } }
    function Invoke-NativeCommand { param([scriptblock]$Command) $global:LASTEXITCODE = 0; $out = & $Command; [pscustomobject]@{ Output = ($out -is [array] ? ($out -join "`n") : $out); ExitCode = 0; Success = $true } }
    # Mock docker command to prevent actual docker calls
    function docker { $global:LASTEXITCODE = 0; return $null }
    function Push-Location { }
    function Pop-Location { }
    function New-Item { return [System.IO.DirectoryInfo]::new("TestDrive:\reports\build-20260530-000000") }

    # Dot-source Images module
    . (Join-Path $script:moduleRoot "Skills\Docker\Modules\SalmonRun.Images\SalmonRun.Images.ps1")

    # Set global variables required by Image functions (they use scope chain lookup)
    Set-Variable -Name TargetDir -Value $script:moduleRoot -Scope Global -Force
    Set-Variable -Name ImageVersion -Value "local" -Scope Global -Force
}

Describe "SalmonRun.Images" -Tag "Images" {
    Context "Invoke-BookkeepingImageBuild" {
        It "runs without error when passed TargetDir" {
            { Invoke-BookkeepingImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }
    }

    Context "Invoke-DocusignImageBuild" {
        It "runs without error when passed TargetDir" {
            { Invoke-DocusignImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }
    }

    Context "Invoke-FunnelProxyImageBuild" {
        It "runs without error when passed TargetDir" {
            { Invoke-FunnelProxyImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }
    }

    Context "Invoke-McpBrowserlessImageBuild" {
        It "runs without error when passed TargetDir" {
            { Invoke-McpBrowserlessImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }
    }

    Context "Invoke-OpencodeImageBuild" {
        It "runs without error when passed TargetDir" {
            { Invoke-OpencodeImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }
    }

    Context "Start-ParallelImageBuild" {
        It "returns hashtable with Jobs and BuildLogDir" {
            $result = Start-ParallelImageBuild -TargetDir $script:moduleRoot
            $result | Should -Not -BeNullOrEmpty
            $result.Keys | Should -Contain "Jobs"
            $result.Keys | Should -Contain "BuildLogDir"
        }

        It "starts background jobs for each image build" {
            $result = Start-ParallelImageBuild -TargetDir $script:moduleRoot
            $result.Jobs.Count | Should -BeGreaterThan 0
        }
    }

    Context "Invoke-FleetImageBuild" {
        It "includes --cache-from flag in docker build command" {
            $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Images\Public\Invoke-FleetImageBuild.ps1") -Raw
            $content | Should -Match "--cache-from"
            $content | Should -Match "fleet:local"
        }
    }

    Context "Invoke-MonitoringImageBuild" {
        It "runs without error when passed TargetDir" {
            Mock Test-Path { return $true }
            Mock Get-ImageSourceHash { return "testhash123" }
            Mock Write-SetupLog { }
            Mock Invoke-DockerWithLogging { }
            Mock Push-Location { }
            Mock Pop-Location { }
            { Invoke-MonitoringImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }
    }

    Context "Invoke-HermesImageBuild" {
        It "runs without error when passed TargetDir" {
            Mock Test-Path { return $true }
            Mock Get-ImageSourceHash { return "testhash123" }
            Mock Write-SetupLog { }
            Mock Invoke-DockerWithLogging { }
            Mock Push-Location { }
            Mock Pop-Location { }
            { Invoke-HermesImageBuild -TargetDir $script:moduleRoot } | Should -Not -Throw
        }

        It "targets hermes.Dockerfile and hermes:local image" {
            $content = Get-Content -Encoding utf8 (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Images\Public\Invoke-HermesImageBuild.ps1") -Raw
            $content | Should -Match "Infrastructure.{1,3}hermes\.Dockerfile"
            $content | Should -Match '"hermes:local"'
            $content | Should -Match "org\.interclaw\.hermes\.source-hash"
        }
    }
}

Describe "SalmonRun.Images manifest RequiredModules" -Tag "Images", "Regression-Only" {
    It "declares RequiredModules with SalmonRun.Core" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Images\SalmonRun.Images.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.ContainsKey("RequiredModules") | Should -Be $true
        $manifest.RequiredModules | Should -Contain "SalmonRun.Core"
    }
}

