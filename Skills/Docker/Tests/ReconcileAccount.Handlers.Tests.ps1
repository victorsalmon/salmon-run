#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# =============================================================================
# Reconcile-account plugin — PowerShell handler contract tests
# =============================================================================

Describe "Invoke-ReconcileHandler" -Tag "ReconcileAccount", "PowerShell" {
    BeforeAll {
        $script:toolPath = Join-Path $PSScriptRoot "..\..\..\Plugins\reconcile-account\tools\Invoke-ReconcileHandler.ps1"
        $script:repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "reconcile-handler-test-$([System.Guid]::NewGuid().ToString())"
        $null = New-Item -ItemType Directory -Path $repoRoot -Force

        # Stub the Salmon modules the harness forces into the PSModulePath
        $salmonModulesRoot = Join-Path $repoRoot "Skills" "Orchestrator" "Salmon" "Modules"
        $dockerModulesRoot = Join-Path $repoRoot "Skills" "Docker" "Modules"
        foreach ($m in @('SalmonRun.Core','SalmonRun.Process','SalmonRun.Audit')) {
            $dir = Join-Path $salmonModulesRoot $m
            $null = New-Item -ItemType Directory -Path $dir -Force
            @"
@{
    RootModule = '$m.psm1'
    ModuleVersion = '1.0.0'
    GUID = '$([Guid]::NewGuid().ToString())'
    PowerShellVersion = '7.0'
}
"@ | Set-Content (Join-Path $dir "$m.psd1") -Encoding utf8
            'function Get-BookkeepingSecretBundle { @{ ZohoClientId = "test"; ZohoClientSecret = "test"; ZohoRefreshToken = "test"; ZohoOrgIdIntersite = "1"; ZohoOrgIdRoomRentals = "2" } }' | Set-Content (Join-Path $dir "$m.psm1") -Encoding utf8
        }

        # Stub the bookkeeping module the harness will load
        $bookkeepingRoot = Join-Path $repoRoot "Skills" "Bookkeeping" "handlers" "SalmonRun.Bookkeeping"
        $null = New-Item -ItemType Directory -Path $bookkeepingRoot -Force
        $manifest = @{
            RootModule = 'SalmonRun.Bookkeeping.psm1'
            ModuleVersion = '1.0.0'
            GUID = [Guid]::NewGuid().ToString()
            PowerShellVersion = '7.0'
            FunctionsToExport = @('Get-TestData')
        }
        @"
@{
    RootModule = 'SalmonRun.Bookkeeping.psm1'
    ModuleVersion = '1.0.0'
    GUID = '$([Guid]::NewGuid().ToString())'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Get-TestData')
}
"@ | Set-Content (Join-Path $bookkeepingRoot "SalmonRun.Bookkeeping.psd1") -Encoding utf8
        @'
function Get-TestData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Name = '',

        [Parameter(Mandatory=$false)]
        [int]$Count = 1
    )
    return [PSCustomObject]@{ Name = $Name; Count = $Count }
}
'@ | Set-Content (Join-Path $bookkeepingRoot "SalmonRun.Bookkeeping.psm1") -Encoding utf8
    }

    AfterAll {
        Get-Module SalmonRun.Bookkeeping -All | Remove-Module -Force -ErrorAction SilentlyContinue
        Get-Module SalmonRun.Core, SalmonRun.Process, SalmonRun.Audit -All | Remove-Module -Force -ErrorAction SilentlyContinue
        if (Test-Path $script:repoRoot) {
            Remove-Item -LiteralPath $script:repoRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "loads the module and returns JSON output for a valid function" {
        $json = & $script:toolPath -FunctionName 'Get-TestData' -ParametersJson '{"Name":"Acme","Count":3}' -RepoRoot $script:repoRoot
        $result = $json | ConvertFrom-Json
        $result.Name | Should -Be 'Acme'
        $result.Count | Should -Be 3
    }

    It "throws when the requested function is not exported" {
        { & $script:toolPath -FunctionName 'Get-MissingFunction' -ParametersJson '{}' -RepoRoot $script:repoRoot } | Should -Throw -ExpectedMessage "*not exported*"
    }

    It "throws for invalid JSON in -ParametersJson" {
        { & $script:toolPath -FunctionName 'Get-TestData' -ParametersJson 'not json' -RepoRoot $script:repoRoot } | Should -Throw -ExpectedMessage "*Invalid -ParametersJson*"
    }

    It "defaults -ParametersJson to an empty object" {
        $json = & $script:toolPath -FunctionName 'Get-TestData' -RepoRoot $script:repoRoot
        $result = $json | ConvertFrom-Json
        $result.Name | Should -BeNullOrEmpty
        $result.Count | Should -Be 1
    }
}
