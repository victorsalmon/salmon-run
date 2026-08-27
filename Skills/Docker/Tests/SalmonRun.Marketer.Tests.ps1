#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer"
    $modulePath = Join-Path $moduleRoot "SalmonRun.Marketer.psd1"
    Get-Module SalmonRun.Marketer -ErrorAction SilentlyContinue | Remove-Module -Force
}

Describe "SalmonRun.Marketer module" -Tag "Marketer", "Regression-Only" {
    It "imports successfully" {
        { Import-Module $modulePath -Force -ErrorAction Stop } | Should -Not -Throw
    }
    It "exports Get-MarketerSecretBundle" {
        (Get-Command Get-MarketerSecretBundle -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}

Describe "Get-MarketerSecretBundle" -Tag "Marketer", "Regression-Only" {
    It "returns a hashtable with expected keys" {
        Import-Module $modulePath -Force -ErrorAction Stop
        $bundle = Get-MarketerSecretBundle
        $bundle | Should -BeOfType [hashtable]
        $bundle.Keys | Should -Contain "AttioWriteKey"
        $bundle.Keys | Should -Contain "AttioReadKey"
        $bundle.Keys | Should -Contain "AttioArchiveKey"
        $bundle.Keys | Should -Contain "HunterApiKey"
        $bundle.Keys | Should -Contain "SmartleadApiKey"
        $bundle.Keys | Should -Contain "OpenrouterApiKey"
        $bundle.Keys | Should -Contain "ApolloApiKey"
        $bundle.Keys | Should -Contain "ZeroBounceApiKey"
    }
}

Describe "Attio.Persons capability gate" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-AttioPerson function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Get-AttioPerson -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-AttioPerson function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command New-AttioPerson -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Update-AttioPerson function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Update-AttioPerson -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Archive-AttioPerson function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Archive-AttioPerson -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Attio.Companies capability gate" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-AttioCompany function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Get-AttioCompany -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-AttioCompany function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command New-AttioCompany -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Update-AttioCompany function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Update-AttioCompany -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Archive-AttioCompany function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Archive-AttioCompany -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Attio.Lists capability gate" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Get-AttioList function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Get-AttioList -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has New-AttioList function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command New-AttioList -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Add-AttioListEntry function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Add-AttioListEntry -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Attio.Notes capability gate" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has New-AttioNote function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command New-AttioNote -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Get-AttioNote function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Get-AttioNote -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Archive-AttioNote function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Archive-AttioNote -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Hunter.EmailFinder" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-HunterSearch function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-HunterSearch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Smartlead.Outreach" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-SmartleadCampaign function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-SmartleadCampaign -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Onboarding.Client" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has New-ClientOnboarding function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command New-ClientOnboarding -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Advance-ClientOnboarding function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Advance-ClientOnboarding -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Get-ClientOnboardingStatus function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Get-ClientOnboardingStatus -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Analysis.RunAnalysis" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-AnalysisRun function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-AnalysisRun -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Apollo.EmailFinder" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-ApolloSearch function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ApolloSearch -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Invoke-ApolloEnrich function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ApolloEnrich -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Invoke-ApolloApi function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ApolloApi -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Invoke-ApolloApiEnrich function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ApolloApiEnrich -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "ZeroBounce.EmailValidation" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "has Invoke-ZeroBounceValidate function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ZeroBounceValidate -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Invoke-ZeroBounceBatchValidate function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ZeroBounceBatchValidate -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "has Invoke-ZeroBounceApi function" {
        InModuleScope SalmonRun.Marketer {
            (Get-Command Invoke-ZeroBounceApi -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It "Invoke-ZeroBounceValidate does not throw NotImplementedException" {
        $handlerPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\ZeroBounce\EmailValidation.ps1"
        $content = Get-Content -Path $handlerPath -Raw
        $content | Should -Not -Match "NotImplementedException"
    }
}

Describe "Test-MarketerCapability" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "returns true when attio:read secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:AttioReadKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'attio:read' } | Should -Not -Throw
        }
    }

    It "returns true when attio:write secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:AttioWriteKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'attio:write' } | Should -Not -Throw
        }
    }

    It "returns true when attio:archive secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:AttioArchiveKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'attio:archive' } | Should -Not -Throw
        }
    }

    It "returns true when hunter:search secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:HunterApiKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'hunter:search' } | Should -Not -Throw
        }
    }

    It "returns true when smartlead:campaign secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:SmartleadApiKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'smartlead:campaign' } | Should -Not -Throw
        }
    }

    It "returns true when analysis:run secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:OpenrouterApiKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'analysis:run' } | Should -Not -Throw
        }
    }

    It "apollo:search returns true when secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:ApolloSearchKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'apollo:search' } | Should -Not -Throw
        }
    }

    It "zerobounce:validate returns true when secret is loaded" {
        InModuleScope SalmonRun.Marketer {
            $script:ZerobounceApiKey = "test-key"
            { Test-MarketerCapability -RequiredCapability 'zerobounce:validate' } | Should -Not -Throw
        }
    }

    It "onboarding:create always returns true" {
        InModuleScope SalmonRun.Marketer {
            { Test-MarketerCapability -RequiredCapability 'onboarding:create' } | Should -Not -Throw
        }
    }

    It "throws UnauthorizedAccessException when attio:read secret is missing" {
        InModuleScope SalmonRun.Marketer {
            $script:AttioReadKey = $null
            { Test-MarketerCapability -RequiredCapability 'attio:read' } | Should -Throw "*Missing required capability*"
        }
    }

    It "throws UnauthorizedAccessException when zerobounce:validate secret is missing" {
        InModuleScope SalmonRun.Marketer {
            $script:ZerobounceApiKey = $null
            { Test-MarketerCapability -RequiredCapability 'zerobounce:validate' } | Should -Throw "*Missing required capability*"
        }
    }

    It "throws for unknown capability" {
        InModuleScope SalmonRun.Marketer {
            { Test-MarketerCapability -RequiredCapability 'unknown:capability' } | Should -Throw "*Unknown capability*"
        }
    }
}

Describe "Rate-limit retry configuration" -Tag "Marketer", "Regression" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "Attio max retries is 3" {
        InModuleScope SalmonRun.Marketer {
            $script:AttioMaxRetries | Should -Be 3
        }
    }
    It "Apollo max retries is 3" {
        InModuleScope SalmonRun.Marketer {
            $script:ApolloMaxRetries | Should -Be 3
        }
    }
    It "Smartlead max retries is 3" {
        InModuleScope SalmonRun.Marketer {
            $script:SmartleadMaxRetries | Should -Be 3
        }
    }
    It "Hunter max retries is 3" {
        InModuleScope SalmonRun.Marketer {
            $script:HunterMaxRetries | Should -Be 3
        }
    }
    It "ZeroBounce max retries is 3" {
        InModuleScope SalmonRun.Marketer {
            $script:ZeroBounceMaxRetries | Should -Be 3
        }
    }
}

Describe "Write-MarketerAuditEntry" -Tag "Marketer", "Regression-Only" {
    BeforeAll {
        Import-Module $modulePath -Force -ErrorAction Stop
    }

    It "writes entry without error" {
        InModuleScope SalmonRun.Marketer {
            { Write-MarketerAuditEntry -Capability 'attio:read' -Action "Test" -Context @{} -Result 'allow' } | Should -Not -Throw
        }
    }
}

Describe "Handler header governance" -Tag "Marketer", "Governance" {
    It "Attio/Persons.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Attio\Persons.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Attio/Companies.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Attio\Companies.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Attio/Lists.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Attio\Lists.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Attio/Notes.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Attio\Notes.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Hunter/EmailFinder.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Hunter\EmailFinder.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Smartlead/Outreach.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Smartlead\Outreach.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Onboarding/Client.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Onboarding\Client.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Analysis/RunAnalysis.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Analysis\RunAnalysis.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "Apollo/EmailFinder.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\Apollo\EmailFinder.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
    It "ZeroBounce/EmailValidation.ps1 has capability header comment" {
        $content = Get-Content (Join-Path $PSScriptRoot "..\Modules\SalmonRun.Marketer\Handlers\ZeroBounce\EmailValidation.ps1") -Raw
        $content | Should -Match "Required keys:"
        $content | Should -Match "Capabilities:"
    }
}
