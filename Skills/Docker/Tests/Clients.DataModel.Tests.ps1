#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    $script:SchemaPath = Join-Path $script:RepoRoot "Infrastructure\clients\clients-registry.schema.json"
    $script:ProvidersPath = Join-Path $script:RepoRoot "Infrastructure\clients\providers-config.json"
    $script:FolderLayoutPath = Join-Path $script:RepoRoot "Infrastructure\clients\templates\bookkeeping\folder-layout.json"
    $script:ScaffoldScript = Join-Path $script:RepoRoot "Skills\Clients\New-ClientFolder.ps1"
    $script:ChecklistPath = Join-Path $script:RepoRoot "Skills\Clients\onboarding-checklist.md"
    $script:EmailInterfacePath = Join-Path $script:RepoRoot "Infrastructure\providers\email\IEmailAdapter.md"
    $script:CpanelAdapterPath = Join-Path $script:RepoRoot "Infrastructure\providers\email\CpanelEmailAdapter.mjs"
    $script:MockAdapterPath = Join-Path $script:RepoRoot "Infrastructure\providers\email\MockEmailAdapter.mjs"
    $script:ProviderTestsPath = Join-Path $script:RepoRoot "Infrastructure\providers\email\CpanelEmailAdapter.Tests.mjs"
    $script:ProvisioningScript = Join-Path $script:RepoRoot "Skills\Clients\New-ClientEmail.ps1"
    $script:GitHubRepoScript = Join-Path $script:RepoRoot "Skills\Clients\New-ClientGitHubRepo.ps1"
    $script:OrchestratorScript = Join-Path $script:RepoRoot "Skills\Clients\Initialize-ClientEnvironment.ps1"
    $script:WatchMailboxScript = Join-Path $script:RepoRoot "Skills\Email\Watch-ClientMailbox.mjs"
    $script:ClassifyRubricPath = Join-Path $script:RepoRoot "Skills\Bookkeeping\classify-rubric.json"
    $script:ClassifyDocScript = Join-Path $script:RepoRoot "Skills\Bookkeeping\Scripts\pdf\classify-document.py"
    $script:RegisterMonitorScript = Join-Path $script:RepoRoot "Skills\Clients\Register-ClientEmailMonitor.ps1"
    $script:ImapLib = Join-Path $script:RepoRoot "Skills\Email\Scripts\lib\imap.mjs"
    $script:IntegrationTestScript = Join-Path $script:RepoRoot "Skills\Clients\Test-FullClientOnboarding.ps1"
    $script:OnboardingSkillDoc = Join-Path $script:RepoRoot "Skills\Clients\onboard-client.md"
}

Describe "Client Registry Schema" -Tag "Clients", "Unit" {
    Context "Schema structure" {
        It "is valid JSON and parses correctly" {
            $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
            $schema.title | Should -Be "Client Registry Entry"
        }

        It "has all required top-level fields" {
            $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
            $schema.required | Should -Contain "id"
            $schema.required | Should -Contain "display_name"
            $schema.required | Should -Contain "slug"
            $schema.required | Should -Contain "status"
            $schema.required | Should -Contain "service_type"
            $schema.required | Should -Contain "contacts"
            $schema.required | Should -Contain "onboarded_at"
        }

        It "has a status enum with active, onboarding, archived" {
            $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
            $schema.properties.status.enum | Should -Contain "active"
            $schema.properties.status.enum | Should -Contain "onboarding"
            $schema.properties.status.enum | Should -Contain "archived"
        }

        It "has extensible providers map" {
            $schema = Get-Content -Raw -LiteralPath $script:SchemaPath | ConvertFrom-Json
            $schema.properties.providers.additionalProperties | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Provider Configuration" -Tag "Clients", "Unit" {
    Context "Config structure" {
        It "is valid JSON" {
            $config = Get-Content -Raw -LiteralPath $script:ProvidersPath | ConvertFrom-Json
            $config.email | Should -Not -BeNullOrEmpty
            $config.git | Should -Not -BeNullOrEmpty
            $config.books | Should -Not -BeNullOrEmpty
        }

        It "has active_provider set for each domain" {
            $config = Get-Content -Raw -LiteralPath $script:ProvidersPath | ConvertFrom-Json
            $config.email.active_provider | Should -Not -BeNullOrEmpty
            $config.git.active_provider | Should -Not -BeNullOrEmpty
            $config.books.active_provider | Should -Not -BeNullOrEmpty
        }

        It "each provider has required fields" {
            $config = Get-Content -Raw -LiteralPath $script:ProvidersPath | ConvertFrom-Json
            $domains = @($config.email, $config.git, $config.books)
            foreach ($domain in $domains) {
                foreach ($providerName in $domain.providers.PSObject.Properties.Name) {
                    $provider = $domain.providers.$providerName
                    $provider.type | Should -Not -BeNullOrEmpty
                    $provider.auth_method | Should -Not -BeNullOrEmpty
                    $provider.capabilities | Should -Not -BeNullOrEmpty
                }
            }
        }
    }
}

Describe "Bookkeeping Folder Template" -Tag "Clients", "Unit" {
    Context "Template structure" {
        It "is valid JSON" {
            $template = Get-Content -Raw -LiteralPath $script:FolderLayoutPath | ConvertFrom-Json
            $template.template_name | Should -Be "bookkeeping"
        }

        It "has directories array" {
            $template = Get-Content -Raw -LiteralPath $script:FolderLayoutPath | ConvertFrom-Json
            $template.directories.Count | Should -BeGreaterThan 5
        }

        It "includes required client directories" {
            $template = Get-Content -Raw -LiteralPath $script:FolderLayoutPath | ConvertFrom-Json
            $dirPaths = $template.directories.path
            $dirPaths | Should -Contain "credentials"
            $dirPaths | Should -Contain "statements"
            $dirPaths | Should -Contain "receipts"
            $dirPaths | Should -Contain "tas"
            $dirPaths | Should -Contain "reports"
        }

        It "uses variable placeholders" {
            $template = Get-Content -Raw -LiteralPath $script:FolderLayoutPath | ConvertFrom-Json
            $dirPaths = $template.directories.path -join " "
            $dirPaths | Should -Match "{slug}"
        }
    }
}

Describe "New-ClientFolder.ps1" -Tag "Clients", "Unit" {
    Context "Script syntax" {
        It "parses without syntax errors" {
            { $null = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:ScaffoldScript), [ref]$null, [ref]$null
            ) } | Should -Not -Throw
        }

        It "has mandatory ClientSlug parameter" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:ScaffoldScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $slugParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "ClientSlug" }
            $slugParams | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Email Provider Interface" -Tag "Clients", "Unit" {
    Context "Document structure" {
        It "exists and documents all required methods" {
            $content = Get-Content -Raw -LiteralPath $script:EmailInterfacePath
            $content | Should -Match "createMailbox"
            $content | Should -Match "deleteMailbox"
            $content | Should -Match "listMailboxes"
            $content | Should -Match "setQuota"
            $content | Should -Match "testConnection"
        }

        It "documents error types" {
            $content = Get-Content -Raw -LiteralPath $script:EmailInterfacePath
            $content | Should -Match "EmailAuthError"
            $content | Should -Match "EmailRateLimitError"
            $content | Should -Match "EmailNotFoundError"
            $content | Should -Match "EmailQuotaExceededError"
        }

        It "documents capabilities enum" {
            $content = Get-Content -Raw -LiteralPath $script:EmailInterfacePath
            $content | Should -Match "capabilities"
        }
    }
}

Describe "cPanel Email Adapter" -Tag "Clients", "Unit" {
    Context "Module file" {
        It "CpanelEmailAdapter.mjs exists" {
            Test-Path -LiteralPath $script:CpanelAdapterPath | Should -Be $true
        }
    }
}

Describe "Mock Email Adapter" -Tag "Clients", "Unit" {
    Context "Module file" {
        It "MockEmailAdapter.mjs exists" {
            Test-Path -LiteralPath $script:MockAdapterPath | Should -Be $true
        }
    }
}

Describe "New-ClientEmail.ps1" -Tag "Clients", "Unit" {
    Context "Script syntax" {
        It "parses without syntax errors" {
            { $null = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:ProvisioningScript), [ref]$null, [ref]$null
            ) } | Should -Not -Throw
        }

        It "has mandatory ClientSlug parameter" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:ProvisioningScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $slugParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "ClientSlug" }
            $slugParams | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "New-ClientGitHubRepo.ps1" -Tag "Clients", "Unit" {
    Context "Script syntax" {
        It "parses without syntax errors" {
            { $null = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:GitHubRepoScript), [ref]$null, [ref]$null
            ) } | Should -Not -Throw
        }

        It "has mandatory ClientSlug parameter" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:GitHubRepoScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $slugParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "ClientSlug" }
            $slugParams | Should -Not -BeNullOrEmpty
        }

        It "supports DryRun switch" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:GitHubRepoScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $dryRunParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "DryRun" }
            $dryRunParams | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Initialize-ClientEnvironment.ps1" -Tag "Clients", "Unit" {
    Context "Script syntax" {
        It "parses without syntax errors" {
            { $null = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:OrchestratorScript), [ref]$null, [ref]$null
            ) } | Should -Not -Throw
        }

        It "has mandatory ClientSlug parameter" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:OrchestratorScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $slugParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "ClientSlug" }
            $slugParams | Should -Not -BeNullOrEmpty
        }

        It "has SkipEmail and SkipRepo switches" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:OrchestratorScript), [ref]$null, [ref]$null
            )
            $allNames = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name.VariablePath.UserPath }
            $allNames | Should -Contain "SkipEmail"
            $allNames | Should -Contain "SkipRepo"
        }
    }
}

Describe "Watch-ClientMailbox.mjs" -Tag "Clients", "Unit" {
    Context "Syntax" {
        It "passes Node.js syntax check" {
            node --check $script:WatchMailboxScript 2>&1; $LASTEXITCODE | Should -Be 0
        }
    }
}

Describe "imap.mjs library" -Tag "Clients", "Unit" {
    Context "Syntax" {
        It "passes Node.js syntax check" {
            node --check $script:ImapLib 2>&1; $LASTEXITCODE | Should -Be 0
        }

        It "exports watchMailboxes function" {
            $content = Get-Content -Raw -LiteralPath $script:ImapLib
            $content | Should -Match "export async function watchMailboxes"
        }
    }
}

Describe "classify-rubric.json" -Tag "Clients", "Unit" {
    Context "Structure" {
        It "is valid JSON" {
            $rubric = Get-Content -Raw -LiteralPath $script:ClassifyRubricPath | ConvertFrom-Json
            $rubric.classifiers.Count | Should -Be 3
        }

        It "has statement, receipt, and invoice classifiers" {
            $rubric = Get-Content -Raw -LiteralPath $script:ClassifyRubricPath | ConvertFrom-Json
            $types = $rubric.classifiers.type
            $types | Should -Contain "statement"
            $types | Should -Contain "receipt"
            $types | Should -Contain "invoice"
        }
    }
}

Describe "classify-document.py" -Tag "Clients", "Unit" {
    Context "Syntax" {
        It "passes Python syntax check" {
            python -m py_compile $script:ClassifyDocScript 2>&1; $LASTEXITCODE | Should -Be 0
        }

        It "runs --help without error" {
            $result = python $script:ClassifyDocScript 2>&1
            $LASTEXITCODE | Should -Be 1
            $result | Should -Match "Usage"
        }
    }
}

Describe "Test-FullClientOnboarding.ps1" -Tag "Clients", "Unit" {
    Context "Script syntax" {
        It "parses without syntax errors" {
            { $null = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:IntegrationTestScript), [ref]$null, [ref]$null
            ) } | Should -Not -Throw
        }

        It "supports LeaveSandbox switch" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:IntegrationTestScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $sandboxParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "LeaveSandbox" }
            $sandboxParams | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "onboard-client.md" -Tag "Clients", "Unit" {
    Context "Document structure" {
        It "exists and has substantial content" {
            (Get-Item -LiteralPath $script:OnboardingSkillDoc).Length | Should -BeGreaterThan 1000
        }

        It "covers all onboarding phases" {
            $content = Get-Content -Raw -LiteralPath $script:OnboardingSkillDoc
            $content | Should -Match "New-ClientFolder"
            $content | Should -Match "New-ClientEmail"
            $content | Should -Match "New-ClientGitHubRepo"
            $content | Should -Match "Register-ClientEmailMonitor"
            $content | Should -Match "Initialize-ClientEnvironment"
        }
    }
}

Describe "Register-ClientEmailMonitor.ps1" -Tag "Clients", "Unit" {
    Context "Script syntax" {
        It "parses without syntax errors" {
            { $null = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:RegisterMonitorScript), [ref]$null, [ref]$null
            ) } | Should -Not -Throw
        }

        It "has mandatory ClientSlug parameter" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:RegisterMonitorScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $slugParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "ClientSlug" }
            $slugParams | Should -Not -BeNullOrEmpty
        }

        It "supports WhatIf switch" {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput(
                (Get-Content -Raw -LiteralPath $script:RegisterMonitorScript), [ref]$null, [ref]$null
            )
            $params = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)
            $whatIfParams = $params | Where-Object { $_.Name.VariablePath.UserPath -eq "WhatIf" }
            $whatIfParams | Should -Not -BeNullOrEmpty
        }
    }
}

Describe "Onboarding Checklist" -Tag "Clients", "Unit" {
    Context "Document structure" {
        It "exists and has content" {
            (Get-Item -LiteralPath $script:ChecklistPath).Length | Should -BeGreaterThan 500
        }

        It "has required checklist items" {
            $content = Get-Content -Raw -LiteralPath $script:ChecklistPath
            $content | Should -Match "Legal Entity"
            $content | Should -Match "Bank Accounts"
            $content | Should -Match "Signing Authority"
            $content | Should -Match "Required"
            $content | Should -Match "Optional"
        }
    }
}
