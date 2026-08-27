#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $script:RepoRoot = Resolve-Path "$PSScriptRoot/../.."
}

Describe "RunFix headless specializations" -Tag "RunFix" {
    $specs = @(
        @{ Name = "cloudtax-login"; File = "runfix-invoke-cloudtax-login.md" },
        @{ Name = "cloudtax-add-form"; File = "runfix-invoke-cloudtax-add-form.md" },
        @{ Name = "cloudtax-fill-form"; File = "runfix-invoke-cloudtax-fill-form.md" },
        @{ Name = "cloudtax-autofill"; File = "runfix-invoke-cloudtax-autofill.md" },
        @{ Name = "homedepot-login"; File = "runfix-invoke-homedepot-login.md" }
    )

    Context "RunFix specialization files exist" {
        It "runfix-invoke-<Name> exists" -TestCases $specs {
            $path = Join-Path $RepoRoot "Skills/Workflows/RunFix" $File
            Test-Path $path | Should -BeTrue
        }

        It "runfix-invoke-<Name> has Mode, Target, and Flags" -TestCases $specs {
            $path = Join-Path $RepoRoot "Skills/Workflows/RunFix" $File
            $content = Get-Content $path -Raw
            $content | Should -Match '\$MODE'
            $content | Should -Match '\$TARGET_SCRIPT'
            $content | Should -Match '\$flags'
        }

        It "runfix-invoke-<Name> has Error Table header" -TestCases $specs {
            $path = Join-Path $RepoRoot "Skills/Workflows/RunFix" $File
            $content = Get-Content $path -Raw
            $content | Should -Match 'Error symptom.*Root cause'
        }

        It "runfix-invoke-<Name> has Rubrics with exit code check" -TestCases $specs {
            $path = Join-Path $RepoRoot "Skills/Workflows/RunFix" $File
            $content = Get-Content $path -Raw
            $content | Should -Match 'Exit code'
        }
    }

    Context "Wrapper scripts exist" {
        It "Invoke-CloudTaxLogin.ps1 exists" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxLogin.ps1") | Should -BeTrue
        }
        It "Invoke-CloudTaxAddForm.ps1 exists" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxAddForm.ps1") | Should -BeTrue
        }
        It "Invoke-CloudTaxFillForm.ps1 exists" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxFillForm.ps1") | Should -BeTrue
        }
        It "Invoke-CloudTaxAutofill.ps1 exists" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxAutofill.ps1") | Should -BeTrue
        }
        It "Invoke-HomeDepotLogin.ps1 exists" {
            Test-Path (Join-Path $RepoRoot "Infrastructure/Browserless/Sites/homedepot.ca/Invoke-HomeDepotLogin.ps1") | Should -BeTrue
        }
    }

    Context "Wrapper syntax validation" {
        $wrappers = @(
            "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxLogin.ps1",
            "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxAddForm.ps1",
            "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxFillForm.ps1",
            "Infrastructure/Browserless/Sites/cloudtax.ca/Invoke-CloudTaxAutofill.ps1",
            "Infrastructure/Browserless/Sites/homedepot.ca/Invoke-HomeDepotLogin.ps1"
        )

        It "<_> parses without syntax errors" -TestCases ($wrappers | ForEach-Object { @{ Path = $_ } }) {
            $fullPath = Join-Path $RepoRoot $Path
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$null, [ref]$errors)
            $errors.Count | Should -Be 0
        }

        It "<_> has -Headless parameter" -TestCases ($wrappers | ForEach-Object { @{ Path = $_ } }) {
            $fullPath = Join-Path $RepoRoot $Path
            $content = Get-Content $fullPath -Raw
            $content | Should -Match '\$Headless'
        }

        It "<_> has INTERCLAW_RUNFIX_ACTIVE guard" -TestCases ($wrappers | ForEach-Object { @{ Path = $_ } }) {
            $fullPath = Join-Path $RepoRoot $Path
            $content = Get-Content $fullPath -Raw
            $content | Should -Match 'INTERCLAW_RUNFIX_ACTIVE'
        }
    }

    Context "Skills manifest registration" {
        It "skills.json has all 5 new entries" {
            $json = Get-Content (Join-Path $RepoRoot "Skills/skills.json") -Raw | ConvertFrom-Json
            $names = $json | Where-Object { $_.name -like 'opencode/runfix-invoke-*' } | ForEach-Object { $_.name }
            $names.Count | Should -Be 5
        }

        It "skills-index.json has all 5 new entries" {
            $json = Get-Content (Join-Path $RepoRoot "Skills/skills-index.json") -Raw | ConvertFrom-Json
            $members = $json.PSObject.Properties | Where-Object { $_.Name -like 'opencode/runfix-invoke-*' }
            $members.Count | Should -Be 5
        }

        It "skills.json and skills-index.json are in sync for new entries" {
            $json = Get-Content (Join-Path $RepoRoot "Skills/skills.json") -Raw | ConvertFrom-Json
            $index = Get-Content (Join-Path $RepoRoot "Skills/skills-index.json") -Raw | ConvertFrom-Json
            $jsonNames = $json | Where-Object { $_.name -like 'opencode/runfix-invoke-*' } | ForEach-Object { $_.name } | Sort-Object
            $indexNames = $index.PSObject.Properties | Where-Object { $_.Name -like 'opencode/runfix-invoke-*' } | ForEach-Object { $_.Name } | Sort-Object
            $jsonNames | Should -Be $indexNames
        }
    }

    Context "opencode.json runfix template" {
        It "runfix command template exists" {
            $config = Get-Content (Join-Path $RepoRoot "opencode.json") -Raw | ConvertFrom-Json
            $config.command.runfix | Should -Not -BeNullOrEmpty
        }

        It "template supports multiple script extensions" {
            $config = Get-Content (Join-Path $RepoRoot "opencode.json") -Raw | ConvertFrom-Json
            $config.command.runfix.template | Should -Match '\.ps1.*\.js|\.js.*\.ps1|file extension'
        }

        It "template has generic script fallback" {
            $config = Get-Content (Join-Path $RepoRoot "opencode.json") -Raw | ConvertFrom-Json
            $config.command.runfix.template | Should -Match 'Generic script fallback|generic defaults'
        }

        It "template has runfixExtraArgs passthrough" {
            $config = Get-Content (Join-Path $RepoRoot "opencode.json") -Raw | ConvertFrom-Json
            $config.command.runfix.template | Should -Match 'runfixExtraArgs'
        }
    }
}
