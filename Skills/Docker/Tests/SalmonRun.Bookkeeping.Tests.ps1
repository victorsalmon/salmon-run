BeforeAll {
    $env:OPENROUTER_API_KEY = "test-vision-key"
    $modulesRoot = Join-Path $PSScriptRoot "..\Modules"
    $salmonModulesRoot = Join-Path $PSScriptRoot "..\..\..\Orchestrator\Modules"
    $env:PSModulePath = "$modulesRoot;$salmonModulesRoot;$env:PSModulePath"

    $bookkeepingModuleRoot = Join-Path $PSScriptRoot "..\..\..\Skills\Bookkeeping\handlers\SalmonRun.Bookkeeping"
    $modulePath = Join-Path $bookkeepingModuleRoot "SalmonRun.Bookkeeping.psd1"
    # Pre-import core module path for SalmonRun.Core's RequiredModules (Paths, Ports, Diagnostics)
    Import-Module SalmonRun.Core -Force -ErrorAction Stop
    Import-Module SalmonRun.Process -Force -ErrorAction Stop
    Import-Module SalmonRun.Audit -Force -ErrorAction Stop
    Get-Module SalmonRun.Bookkeeping -ErrorAction SilentlyContinue | Remove-Module -Force
}
Describe "SalmonRun.Bookkeeping module" -Tag "Bookkeeping", "Regression-Only" {
    It "imports successfully" {
        { Import-Module $modulePath -Force -ErrorAction Stop } | Should -Not -Throw
    }
    It "exports Get-BookkeepingSecretBundle" {
        (Get-Command Get-BookkeepingSecretBundle -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe "Get-BookkeepingSecretBundle" -Tag "Bookkeeping", "Regression-Only" {
    It "returns a hashtable with expected keys" {
        Import-Module $modulePath -Force -ErrorAction Stop
        $bundle = Get-BookkeepingSecretBundle
        $bundle | Should -BeOfType [hashtable]
        $bundle.Keys | Should -Contain "ZohoClientId"
        $bundle.Keys | Should -Contain "ZohoClientSecret"
        $bundle.Keys | Should -Contain "ZohoRefreshToken"
    }
}

Describe "Zoho.Expenses capability gate" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-ZohoExpense function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Get-ZohoExpense -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-ZohoExpense function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command New-ZohoExpense -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Attach-ReceiptToExpense function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Attach-ReceiptToExpense -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "Get-ZohoExpenses maps has_attachment (not has_receipt) — regression for field-name bug" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers/Zoho/Expenses.ps1") -Raw
        $content | Should -Match '\$_\.has_attachment'
        # The `has_receipt` field does not exist on Zoho's /expenses endpoint
        # and reading it always yields $null, which silently broke the old
        # HasReceipt mapping. The handler must read has_attachment instead.
        $content | Should -Not -Match '\$_\.has_receipt'
    }
    It "Get-ZohoExpenses exposes both HasAttachment and HasReceipt compatibility alias" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers/Zoho/Expenses.ps1") -Raw
        $content | Should -Match 'HasAttachment\s*='
        $content | Should -Match 'HasReceipt\s*='
    }
    It "Get-ZohoExpense exposes Documents and AttachmentStatus" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers/Zoho/Expenses.ps1") -Raw
        $content | Should -Match 'Documents\s*='
        $content | Should -Match 'AttachmentStatus\s*='
    }
    It "Get-ZohoExpense keeps ReceiptUrl with a back-compat comment" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers/Zoho/Expenses.ps1") -Raw
        $content | Should -Match 'ReceiptUrl\s*='
        # The handler must explain why ReceiptUrl is still mapped despite being
        # always null in Zoho's API response.
        $content | Should -Match 'always null'
    }
}

Describe "Zoho.Contacts (implemented)" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-ZohoContacts function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Get-ZohoContacts -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-ZohoContact function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command New-ZohoContact -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "Get-ZohoContacts does not throw stub exception" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Contacts.ps1") -Raw
        $content | Should -Not -Match "throw \[System\.NotImplementedException\]"
    }
    It "Contacts.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Contacts.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
}

Describe "Zoho.Invoices (implemented)" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-ZohoInvoices function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Get-ZohoInvoices -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-ZohoInvoice function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command New-ZohoInvoice -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "Get-ZohoInvoices does not throw stub exception" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Invoices.ps1") -Raw
        $content | Should -Not -Match "throw \[System\.NotImplementedException\]"
    }
    It "Invoices.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Invoices.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
}

Describe "Zoho.ChartOfAccounts (new)" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-ZohoChartOfAccounts function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Get-ZohoChartOfAccounts -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-ZohoChartOfAccount function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command New-ZohoChartOfAccount -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Zoho.Transfers (implemented)" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-ZohoTransfers function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Get-ZohoTransfers -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-ZohoTransfer function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command New-ZohoTransfer -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "Get-ZohoTransfers does not throw stub exception" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Transfers.ps1") -Raw
        $content | Should -Not -Match "throw \[System\.NotImplementedException\]"
    }
    It "Transfers.ps1 has capability header comment for read and write" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Transfers.ps1") -Raw
        $content | Should -Match "zoho:transfer:read"
        $content | Should -Match "zoho:transfer:write"
    }
    It "Transfers.ps1 contains Invoke-ZohoTransfersApi private helper" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Transfers.ps1") -Raw
        $content | Should -Match "function Invoke-ZohoTransfersApi"
    }
    It "Test-BookkeepingCapability has zoho:transfer:read and zoho:transfer:write" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Private\Test-BookkeepingCapability.ps1") -Raw
        $content | Should -Match "'zoho:transfer:read'"
        $content | Should -Match "'zoho:transfer:write'"
    }
}

Describe "Vision.ReceiptOcr" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-ReceiptOcr function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Invoke-ReceiptOcr -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Save-VisionOutput function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Save-VisionOutput -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Plaid.Sync" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "does not load deprecated Plaid handlers" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Sync-PlaidTransactions -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        }
    }
}

Describe "Test-BookkeepingCapability" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "does not throw when required secret is loaded" {
        InModuleScope SalmonRun.Bookkeeping {
            $script:ZohoClientId = "test"
            $script:ZohoClientSecret = "test"
            $script:ZohoRefreshToken = "test"
            { Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read' } | Should -Not -Throw
        }
    }
    It "emits no output to caller pipeline on success (regression for handler array-leak bug)" {
        InModuleScope SalmonRun.Bookkeeping {
            $script:ZohoClientId = "test"
            $script:ZohoClientSecret = "test"
            $script:ZohoRefreshToken = "test"
            # Bare call must not produce any output. If it did, downstream
            # handlers that call Test-BookkeepingCapability as a guard would
            # leak $true into their return pipeline, producing arrays where
            # scalars are expected.
            $captured = Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read' 4>&1 5>&1 6>&1
            ($captured | Measure-Object).Count | Should -Be 0
        }
    }

    It "throws UnauthorizedAccessException when secret is missing" {
        InModuleScope SalmonRun.Bookkeeping {
            $script:ZohoClientId = $null
            $script:ZohoClientSecret = $null
            $script:ZohoRefreshToken = $null
            { Test-BookkeepingCapability -RequiredCapability 'zoho:expense:read' } | Should -Throw "*Missing required capability*"
        }
    }

    It "throws for unknown capability" {
        InModuleScope SalmonRun.Bookkeeping {
            { Test-BookkeepingCapability -RequiredCapability 'unknown:capability' } | Should -Throw "*Unknown capability*"
        }
    }

    It "vision:ocr always available" {
        InModuleScope SalmonRun.Bookkeeping {
            { Test-BookkeepingCapability -RequiredCapability 'vision:ocr' } | Should -Not -Throw
        }
    }
}

Describe "Write-BookkeepingAuditEntry" -Tag "Bookkeeping", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "writes entry without error" {
        InModuleScope SalmonRun.Bookkeeping {
            { Write-BookkeepingAuditEntry -Capability 'zoho:expense:read' -Action "Test" -Context @{} -Result 'allow' } | Should -Not -Throw
        }
    }
}

Describe "Zoho.Auth token cache" -Tag "Bookkeeping", "Core", "Regression" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Load-ZohoTokenCache function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Load-ZohoTokenCache -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Save-ZohoTokenCache function" {
        InModuleScope SalmonRun.Bookkeeping {
            (Get-Command Save-ZohoTokenCache -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "Auth.ps1 declares ZohoTokenCachePath constant" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Auth.ps1") -Raw
        $content | Should -Match 'ZohoTokenCachePath\s*='
    }
    It "Save-ZohoTokenCache writes a valid JSON cache file" {
        InModuleScope SalmonRun.Bookkeeping {
            $testToken = "test-token-12345"
            $testExpiry = [datetime]::UtcNow.AddHours(1)
            $testPath = [System.IO.Path]::GetTempFileName()
            try {
                $script:ZohoTokenCachePath = $testPath
                Save-ZohoTokenCache -Token $testToken -Expiry $testExpiry
                $cached = Get-Content $testPath -Raw | ConvertFrom-Json
                $cached.access_token | Should -Be $testToken
                $cached.expires_at | Should -Not -BeNullOrEmpty
                $cached.cached_at | Should -Not -BeNullOrEmpty
            } finally {
                Remove-Item $testPath -Force -ErrorAction SilentlyContinue
                $script:ZohoTokenCachePath = "/app/zoho-token-cache.json"
            }
        }
    }
    It "Load-ZohoTokenCache reads back a saved token" {
        InModuleScope SalmonRun.Bookkeeping {
            $testToken = "test-load-token"
            $testExpiry = [datetime]::UtcNow.AddHours(1)
            $testPath = [System.IO.Path]::GetTempFileName()
            try {
                $script:ZohoTokenCachePath = $testPath
                $script:ZohoAccessTokenValue = $null
                $script:ZohoAccessTokenExpiry = $null
                Save-ZohoTokenCache -Token $testToken -Expiry $testExpiry
                Load-ZohoTokenCache
                $script:ZohoAccessTokenValue | Should -Be $testToken
            } finally {
                Remove-Item $testPath -Force -ErrorAction SilentlyContinue
                $script:ZohoTokenCachePath = "/app/zoho-token-cache.json"
                $script:ZohoAccessTokenValue = $null
                $script:ZohoAccessTokenExpiry = $null
            }
        }
    }
    It "Load-ZohoTokenCache skips expired tokens" {
        InModuleScope SalmonRun.Bookkeeping {
            $testToken = "expired-token"
            $testExpiry = [datetime]::UtcNow.AddHours(-2)
            $testPath = [System.IO.Path]::GetTempFileName()
            try {
                $script:ZohoTokenCachePath = $testPath
                $script:ZohoAccessTokenValue = $null
                $script:ZohoAccessTokenExpiry = $null
                Save-ZohoTokenCache -Token $testToken -Expiry $testExpiry
                Load-ZohoTokenCache
                $script:ZohoAccessTokenValue | Should -BeNullOrEmpty
            } finally {
                Remove-Item $testPath -Force -ErrorAction SilentlyContinue
                $script:ZohoTokenCachePath = "/app/zoho-token-cache.json"
            }
        }
    }
}

Describe "Handler header governance" -Tag "Bookkeeping", "Governance" {
    It "Zoho.Expenses.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Zoho\Expenses.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Vision.ReceiptOcr.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $bookkeepingModuleRoot "Handlers\Vision\ReceiptOcr.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
}
