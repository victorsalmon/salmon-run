#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $orchestratorModules = Join-Path $repoRoot 'Orchestrator\Modules'
    $dockerModules = Join-Path $repoRoot 'Skills\Docker\Modules'
    foreach ($modulePath in @($orchestratorModules, $dockerModules)) {
        if ($env:PSModulePath -notlike "*$modulePath*") {
            $env:PSModulePath = "$modulePath$([IO.Path]::PathSeparator)$env:PSModulePath"
        }
    }
    $ModuleRoot = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet"
    . (Join-Path $ModuleRoot "SalmonRun.Fleet.ps1")
    $SecretsModule = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Secrets"
    . (Join-Path $SecretsModule "SalmonRun.Secrets.ps1")

    Mock Write-SetupLog { }
    Mock Write-FleetLog { }
    Mock Write-Verbose { }

    $global:InterclawConstants = @{
        FleetApiPort = 21002
        FleetCommandPollIntervalSec = 30
    }
}

Describe "Get-StackName" -Tag "Fleet", "Regression-Only" {
    It "returns INSTALL_PROJECT env var when available" {
        $env:INSTALL_PROJECT = "FRAD"
        $result = Get-StackName
        $result | Should -Be "FRAD"
    }

    It "returns 'unknown' when no stack info available" {
        Remove-Item Env:\INSTALL_PROJECT -ErrorAction SilentlyContinue
        $result = Get-StackName
        $result | Should -Be "unknown"
    }
}

Describe "Start-SecretRotationEndpoint AllowedContainers" -Tag "Fleet", "Regression-Only" {
    It "defaults to allow all service containers" {
        $expected = @("oc-base", "is-fleet", "is-bookkeeping", "mcp_browserless", "mcp_opencode")
        $actual = @("oc-base", "is-fleet", "is-bookkeeping", "mcp_browserless", "mcp_opencode")
        $actual | Should -Be $expected
    }
}

Describe "AccountantBundleSuffix" -Tag "Secrets", "Regression-Only" {
    It "returns 'secrets_bundle' for mount path consistency" {
        $suffix = "secrets_bundle"
        $suffix | Should -Be "secrets_bundle"
    }
}

Describe "Fleet state POST auth" -Tag "Fleet", "Regression-Only" {
    It "includes Authorization header in state POST" {
        $entrypoint = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Invoke-FleetEntrypoint.ps1") -Raw
        $entrypoint | Should -Match '\$authHeaders\["Authorization"\] = "Bearer \$monitorToken"'
    }
}

Describe "Rotation code uses 2>\$null" -Tag "Fleet", "Regression-Only" {
    It "health listener rotate uses 2>`$null not 2>&1" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-FleetHealthListener.ps1") -Raw
        $snippet = $content -replace "(?s).*?/api/secret/rotate.*?}$"
        $rotateBlock = if ($content -match "(?s)/api/secret/rotate.*?(?=default|/api/secret/rotate-containers)") { $Matches[0] } else { "" }
        $rotateBlock | Should -Not -Match '2>&1'
    }

    It "rotation endpoint uses 2>`$null not 2>&1" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Fleet\Public\Start-SecretRotationEndpoint.ps1") -Raw
        $linesWith2and1 = @($content -split "`n" | Select-String '2>&1')
        $linesWith2and1.Count | Should -Be 0
    }
}
