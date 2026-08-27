#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# =============================================================================
# SalmonRun.Bookkeeping handler behavior tests (dot-sourced, dependency-free)
# =============================================================================

Describe "Get-BookkeepingSecretBundle" -Tag "ReconcileAccount", "PowerShell", "Bookkeeping" {
    BeforeAll {
        $script:srcPath = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\handlers\SalmonRun.Bookkeeping\Public\Get-BookkeepingSecretBundle.ps1"

        # Stub dependencies used during secret resolution
        function Write-SetupLog { param([string]$Message, [string]$Level) }
        function Get-SecretFromAws { param([string]$KeyName) }
        function Read-ProxySecret { param([string]$KeyName) }

        . $script:srcPath

        $env:ZOHO_BOOKS_ID = 'test-client-id'
        $env:ZOHO_BOOKS_SECRET = 'test-client-secret'
        $env:ZOHO_BOOKS_REFRESH = 'test-refresh'
        $env:ZOHO_BOOKS_ORG_INTERSITE = '123456'
        $env:ZOHO_BOOKS_ORG_RENTALS = '789012'
    }

    AfterAll {
        $env:ZOHO_BOOKS_ID = $null
        $env:ZOHO_BOOKS_SECRET = $null
        $env:ZOHO_BOOKS_REFRESH = $null
        $env:ZOHO_BOOKS_ORG_INTERSITE = $null
        $env:ZOHO_BOOKS_ORG_RENTALS = $null
    }

    It "assembles a hashtable from environment variables" {
        $bundle = Get-BookkeepingSecretBundle
        $bundle.ZohoClientId | Should -Be 'test-client-id'
        $bundle.ZohoClientSecret | Should -Be 'test-client-secret'
        $bundle.ZohoRefreshToken | Should -Be 'test-refresh'
        $bundle.ZohoOrgIdIntersite | Should -Be '123456'
        $bundle.ZohoOrgIdRoomRentals | Should -Be '789012'
    }

    It "falls back to an empty bundle when no env vars or files are present" {
        $env:ZOHO_BOOKS_ID = $null
        $bundle = Get-BookkeepingSecretBundle
        $bundle.ZohoClientId | Should -BeNullOrEmpty
        $bundle.VisionApiKey | Should -BeNullOrEmpty
    }
}
