#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web"
    $modulePath = Join-Path $moduleRoot "SalmonRun.Web.psd1"
    Get-Module SalmonRun.Web -ErrorAction SilentlyContinue | Remove-Module -Force
}

Describe "SalmonRun.Web module" -Tag "Web", "Regression-Only" {
    It "imports successfully" {
        { Import-Module $modulePath -Force -ErrorAction Stop } | Should -Not -Throw
    }
    It "exports Get-WebSecretBundle" {
        (Get-Command Get-WebSecretBundle -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It "exports Invoke-WebSearch" {
        (Get-Command Invoke-WebSearch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe "Get-WebSecretBundle" -Tag "Web", "Regression-Only" {
    It "returns a hashtable with expected keys" {
        Import-Module $modulePath -Force -ErrorAction Stop
        $bundle = Get-WebSecretBundle
        $bundle | Should -BeOfType [hashtable]
        $bundle.Keys | Should -Contain "tavily_api_key"
        $bundle.Keys | Should -Contain "firecrawl_api_key"
    }
}

Describe "Email.Send capability gate" -Tag "Web", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Send-EmailMessage function" {
        InModuleScope SalmonRun.Web {
            (Get-Command Send-EmailMessage -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Search.Tavily capability gate" -Tag "Web", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-TavilySearch function" {
        InModuleScope SalmonRun.Web {
            (Get-Command Invoke-TavilySearch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Invoke-TavilyFetch function" {
        InModuleScope SalmonRun.Web {
            (Get-Command Invoke-TavilyFetch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Search.Firecrawl capability gate" -Tag "Web", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-FirecrawlScrape function" {
        InModuleScope SalmonRun.Web {
            (Get-Command Invoke-FirecrawlScrape -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Test-WebCapability" -Tag "Web", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "returns true when required secret is loaded" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = "test"
            { Test-WebCapability -RequiredCapability 'search:tavily' } | Should -Not -Throw
        }
    }

    It "throws UnauthorizedAccessException when secret is missing" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            { Test-WebCapability -RequiredCapability 'search:tavily' } | Should -Throw "*Missing required capability*"
        }
    }

    It "throws for unknown capability" {
        InModuleScope SalmonRun.Web {
            { Test-WebCapability -RequiredCapability 'unknown:capability' } | Should -Throw "*Unknown capability*"
        }
    }

    It "email:send always returns true" {
        InModuleScope SalmonRun.Web {
            { Test-WebCapability -RequiredCapability 'email:send' } | Should -Not -Throw
        }
    }
}

Describe "Test-WebContainerAccess" -Tag "Web", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "returns true when container name matches allowed list" {
        InModuleScope SalmonRun.Web {
            $env:CONTAINER_NAME = "opencode"
            { Test-WebContainerAccess } | Should -Not -Throw
        }
    }

    It "throws when container name is not in allowed list" {
        InModuleScope SalmonRun.Web {
            $env:CONTAINER_NAME = "unknown-container"
            { Test-WebContainerAccess } | Should -Throw "*Container access denied*"
        }
    }

    It "throws when CONTAINER_NAME is not set" {
        InModuleScope SalmonRun.Web {
            $env:CONTAINER_NAME = $null
            { Test-WebContainerAccess } | Should -Throw "*CONTAINER_NAME*"
        }
    }
}

Describe "Write-WebAuditEntry" -Tag "Web", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "writes entry without error" {
        InModuleScope SalmonRun.Web {
            { Write-WebAuditEntry -Capability 'drive:file:read' -Action "Test" -Context @{} -Result 'allow' } | Should -Not -Throw
        }
    }
}

Describe "Handler header governance" -Tag "Web", "Governance" {
    It "Email/Send.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Handlers\Email\Send.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Search/Tavily.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Handlers\Search\Tavily.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Search/Firecrawl.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Web\Handlers\Search\Firecrawl.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
}

Describe "Usage tracking state" -Tag "Web" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "TavilyUsage hashtable exists with TotalCalls" {
        InModuleScope SalmonRun.Web {
            $script:TavilyUsage | Should -Not -BeNullOrEmpty
            $script:TavilyUsage.TotalCalls | Should -BeGreaterOrEqual 0
        }
    }

    It "FirecrawlUsage hashtable exists with TotalCalls" {
        InModuleScope SalmonRun.Web {
            $script:FirecrawlUsage | Should -Not -BeNullOrEmpty
            $script:FirecrawlUsage.TotalCalls | Should -BeGreaterOrEqual 0
        }
    }

    It "TavilyUsage tracks KeyExhausted flag" {
        InModuleScope SalmonRun.Web {
            $script:TavilyUsage.Keys | Should -Contain "KeyExhausted"
            $script:TavilyUsage.Keys | Should -Contain "LastExhaustedAt"
            $script:TavilyUsage.Keys | Should -Contain "RemainingQuota"
        }
    }

    It "FirecrawlUsage tracks KeyExhausted flag" {
        InModuleScope SalmonRun.Web {
            $script:FirecrawlUsage.Keys | Should -Contain "KeyExhausted"
            $script:FirecrawlUsage.Keys | Should -Contain "LastExhaustedAt"
            $script:FirecrawlUsage.Keys | Should -Contain "RemainingQuota"
        }
    }
}

Describe "429 key exhaustion detection" -Tag "Web", "Regression" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "Invoke-TavilySearch increments TotalCalls on missing key" {
        InModuleScope SalmonRun.Web {
            $before = $script:TavilyUsage.TotalCalls
            $script:tavily_api_key = $null
            $r = Invoke-TavilySearch -Query "test"
            $script:TavilyUsage.TotalCalls | Should -Be ($before + 1)
        }
    }

    It "Invoke-FirecrawlScrape increments TotalCalls on missing key" {
        InModuleScope SalmonRun.Web {
            $before = $script:FirecrawlUsage.TotalCalls
            $script:firecrawl_api_key = $null
            $r = Invoke-FirecrawlScrape -Url "https://example.com"
            $script:FirecrawlUsage.TotalCalls | Should -Be ($before + 1)
        }
    }

    It "Invoke-TavilySearch includes Usage in 429 error response" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $r = Invoke-TavilySearch -Query "test"
            $r.StatusCode | Should -Be 401  # missing key returns 401, not 429
            $r.Usage | Should -Not -BeNullOrEmpty
            $r.Usage.TotalCalls | Should -BeGreaterOrEqual 0
        }
    }

    It "Invoke-WebSearch includes RemainingQuota on success" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $script:firecrawl_api_key = $null
            $r = Invoke-WebSearch -Query "test" -Backend auto
            $r.Success | Should -Be $false
        }
    }

    It "Invoke-WebSearch returns StatusCode when all backends fail" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $script:firecrawl_api_key = $null
            $r = Invoke-WebSearch -Query "test" -Backend auto
            $r.StatusCode | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "401/403 graceful degradation" -Tag "Web", "Regression" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "Invoke-TavilySearch returns Success=$false with StatusCode 401 on missing key" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $r = Invoke-TavilySearch -Query "test"
            $r.Success | Should -Be $false
            $r.StatusCode | Should -Be 401
        }
    }

    It "Invoke-TavilyFetch returns Success=$false with StatusCode 401 on missing key" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $r = Invoke-TavilyFetch -Url "https://example.com"
            $r.Success | Should -Be $false
            $r.StatusCode | Should -Be 401
        }
    }

    It "Invoke-FirecrawlScrape returns Success=$false with StatusCode 401 on missing key" {
        InModuleScope SalmonRun.Web {
            $script:firecrawl_api_key = $null
            $r = Invoke-FirecrawlScrape -Url "https://example.com"
            $r.Success | Should -Be $false
            $r.StatusCode | Should -Be 401
        }
    }

    It "Invoke-WebSearch returns degraded result with Success=$false when all backends fail" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $script:firecrawl_api_key = $null
            $r = Invoke-WebSearch -Query "test" -Backend auto
            $r.Success | Should -Be $false
            $r.Error | Should -Not -BeNullOrEmpty
        }
    }

    It "Invoke-WebSearch returns Attempts array in degraded response" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $script:firecrawl_api_key = $null
            $r = Invoke-WebSearch -Query "test" -Backend auto
            $r.Attempts | Should -Not -BeNullOrEmpty
            $r.Attempts.Count | Should -BeGreaterOrEqual 2
        }
    }

    It "Invoke-WebSearch returns Success=$true when firecrawl fallback succeeds after tavily 401" {
        InModuleScope SalmonRun.Web {
            $script:tavily_api_key = $null
            $script:firecrawl_api_key = $null
            $r = Invoke-WebSearch -Query "test" -Backend tavily
            $r.Attempts | Should -Not -BeNullOrEmpty
            $r.Attempts.Count | Should -BeGreaterOrEqual 1
            $r.Attempts[0].Backend | Should -Be "tavily"
        }
    }

    It "Get-WebSecretBundle warns on missing keys" {
        InModuleScope SalmonRun.Web {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq "Get-SecretFromAws" }
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq "Read-ProxySecret" }
            $warnings = @()
            Mock Write-Warning { $warnings += $args[0] }
            $bundle = Get-WebSecretBundle
            $warnings.Count | Should -BeGreaterOrEqual 1
            $warnings[0] | Should -Match "missing keys"
        }
    }
}

Describe "Search.Firecrawl search contract" -Tag "Web", "Regression" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-FirecrawlSearch function" {
        InModuleScope SalmonRun.Web {
            (Get-Command Invoke-FirecrawlSearch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }

    It "Invoke-FirecrawlSearch returns 401 when the key is missing" {
        InModuleScope SalmonRun.Web {
            $script:firecrawl_api_key = $null
            $r = Invoke-FirecrawlSearch -Query "test"
            $r.Success | Should -Be $false
            $r.StatusCode | Should -Be 401
        }
    }

    It "search:firecrawl capability is registered in Test-WebCapability" {
        InModuleScope SalmonRun.Web {
            $script:firecrawl_api_key = "test"
            { Test-WebCapability -RequiredCapability 'search:firecrawl' } | Should -Not -Throw
            $script:firecrawl_api_key = $null
            { Test-WebCapability -RequiredCapability 'search:firecrawl' } | Should -Throw "*Missing required capability*"
        }
    }

    It "Invoke-FirecrawlScrape rejects free-text input with 400" {
        InModuleScope SalmonRun.Web {
            $r = Invoke-FirecrawlScrape -Url "latest AWS pricing"
            $r.Success | Should -Be $false
            $r.StatusCode | Should -Be 400
        }
    }

    It "Invoke-WebSearch tavily fallback calls Firecrawl search, not scrape" {
        InModuleScope SalmonRun.Web {
            $origTavily = (Get-Item function:Invoke-TavilySearch).ScriptBlock
            $origFcSearch = (Get-Item function:Invoke-FirecrawlSearch).ScriptBlock
            $origFcScrape = (Get-Item function:Invoke-FirecrawlScrape).ScriptBlock
            $origAudit = (Get-Item function:Write-WebAuditEntry).ScriptBlock
            try {
                $script:fcScrapeCalls = @()
                Set-Item function:Invoke-TavilySearch -Value { return [pscustomobject]@{ Success = $false; StatusCode = 401; Message = "key rejected"; RemainingQuota = $null } }
                Set-Item function:Invoke-FirecrawlSearch -Value { return [pscustomobject]@{ Success = $true; Results = @([pscustomobject]@{ Title = "hit"; Url = "https://example.com"; Content = "content" }); RemainingQuota = 100 } }
                Set-Item function:Invoke-FirecrawlScrape -Value { param($Url) $script:fcScrapeCalls += $Url; return [pscustomobject]@{ Success = $false; StatusCode = 400; Message = "scrape must not be called" } }
                Set-Item function:Write-WebAuditEntry -Value { param($Capability, $Action, $Context, $Result) }
                $r = Invoke-WebSearch -Query "latest AWS pricing" -Backend tavily
                $r.Success | Should -Be $true
                $r.Backend | Should -Be "firecrawl"
                $r.Results.Count | Should -Be 1
                $script:fcScrapeCalls.Count | Should -Be 0
            } finally {
                Set-Item function:Invoke-TavilySearch -Value $origTavily
                Set-Item function:Invoke-FirecrawlSearch -Value $origFcSearch
                Set-Item function:Invoke-FirecrawlScrape -Value $origFcScrape
                Set-Item function:Write-WebAuditEntry -Value $origAudit
            }
        }
    }

    It "Invoke-WebSearch firecrawl backend routes query to search function" {
        InModuleScope SalmonRun.Web {
            $origFcSearch = (Get-Item function:Invoke-FirecrawlSearch).ScriptBlock
            $origAudit = (Get-Item function:Write-WebAuditEntry).ScriptBlock
            try {
                $script:fcSearchQueries = @()
                Set-Item function:Invoke-FirecrawlSearch -Value { param($Query) $script:fcSearchQueries += $Query; return [pscustomobject]@{ Success = $true; Results = @([pscustomobject]@{ Title = "hit"; Url = "https://example.com"; Content = "content" }); RemainingQuota = 100 } }
                Set-Item function:Write-WebAuditEntry -Value { param($Capability, $Action, $Context, $Result) }
                $r = Invoke-WebSearch -Query "latest AWS pricing" -Backend firecrawl
                $r.Success | Should -Be $true
                $script:fcSearchQueries | Should -Contain "latest AWS pricing"
            } finally {
                Set-Item function:Invoke-FirecrawlSearch -Value $origFcSearch
                Set-Item function:Write-WebAuditEntry -Value $origAudit
            }
        }
    }
}
