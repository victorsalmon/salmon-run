#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "DSH provider contract" -Tag "Contract", "Regression" {
    BeforeAll {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $modulesDir = Join-Path $repoRoot 'Modules'
        $sep = [System.IO.Path]::PathSeparator
        $env:PSModulePath = "$modulesDir$sep$env:PSModulePath"

        $script:DshExecutor = Join-Path $repoRoot 'Modules' 'SalmonRun.PondEngine' 'Executors' 'Dsh.ps1'
        if (-not (Test-Path -LiteralPath $script:DshExecutor)) {
            throw "DSH executor not found at $($script:DshExecutor)"
        }

        # Ensure the PlanLog command exists so Write-PlanLog does not try to
        # source it from disk during the test; we mock it below.
        if (-not (Get-Command Add-PlanPondLog -ErrorAction SilentlyContinue)) {
            function Add-PlanPondLog { param($PlanPath, $Entry) }
        }

        # Dot-source the executor so its internal functions (Invoke-DshProvider,
        # Resolve-DshCredential, Resolve-DshModelSlug, New-DshPatchFile) are
        # available in-scope. Mandatory params are satisfied with throwaway
        # values; the actual values are reassigned per-test before invoking
        # Invoke-DshProvider.
        $dummyLane = Join-Path $TestDrive 'lane'
        $dummyRepo = Join-Path $TestDrive 'repo'
        $dummyPlan = Join-Path $TestDrive 'plan.md'
        . $script:DshExecutor -Role coder -LanePath $dummyLane -RepoDir $dummyRepo -PlanFiles $dummyPlan

        # Use an isolated SALMON_RUN_HOME with an empty .env so the unit tests
        # are not affected by a real ~/.salmon/.env. The live context restores
        # the real home before its run.
        $script:SavedSalmonHome = $env:SALMON_RUN_HOME
        $script:TestSalmonHome = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'salmon-home') -Force
        '' | Set-Content -LiteralPath (Join-Path $script:TestSalmonHome.FullName '.env') -Encoding utf8 -NoNewline
        $env:SALMON_RUN_HOME = $script:TestSalmonHome.FullName

        $script:SavedDeepseekKey = $env:DEEPSEEK_API_KEY
        $script:SavedOpenrouterKey = $env:OPENROUTER_API_KEY
        $script:SavedDeepinfraKey = $env:DEEPINFRA_API_KEY
        $script:SavedDeepseekBaseUrl = $env:DEEPSEEK_BASE_URL
    }

    AfterAll {
        if ($null -ne $script:SavedSalmonHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonHome }
        else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }

        if ($null -ne $script:SavedDeepseekKey) { $env:DEEPSEEK_API_KEY = $script:SavedDeepseekKey }
        else { Remove-Item Env:\DEEPSEEK_API_KEY -ErrorAction SilentlyContinue }
        if ($null -ne $script:SavedOpenrouterKey) { $env:OPENROUTER_API_KEY = $script:SavedOpenrouterKey }
        else { Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue }
        if ($null -ne $script:SavedDeepinfraKey) { $env:DEEPINFRA_API_KEY = $script:SavedDeepinfraKey }
        else { Remove-Item Env:\DEEPINFRA_API_KEY -ErrorAction SilentlyContinue }
        if ($null -ne $script:SavedDeepseekBaseUrl) { $env:DEEPSEEK_BASE_URL = $script:SavedDeepseekBaseUrl }
        else { Remove-Item Env:\DEEPSEEK_BASE_URL -ErrorAction SilentlyContinue }
    }

    Context "Credential resolution through SalmonRun.Credentials (never logged)" {
        BeforeEach {
            Remove-Item Env:\DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\DEEPINFRA_API_KEY -ErrorAction SilentlyContinue
        }

        AfterEach {
            Remove-Item Env:\DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\OPENROUTER_API_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\DEEPINFRA_API_KEY -ErrorAction SilentlyContinue
        }

        It "Resolve-DshCredential resolves DEEPSEEK_API_KEY from the environment for provider 'dsh'" {
            $env:DEEPSEEK_API_KEY = 'fake-deepseek-key-12345'
            $key = Resolve-DshCredential -Provider 'dsh'
            $key | Should -Be 'fake-deepseek-key-12345'
        }

        It "Resolve-DshCredential resolves OPENROUTER_API_KEY from the environment for provider 'openrouter'" {
            $env:OPENROUTER_API_KEY = 'fake-openrouter-key-67890'
            $key = Resolve-DshCredential -Provider 'openrouter'
            $key | Should -Be 'fake-openrouter-key-67890'
        }

        It "Resolve-DshCredential resolves DEEPINFRA_API_KEY from the environment for provider 'deepinfra'" {
            $env:DEEPINFRA_API_KEY = 'fake-deepinfra-key-abcde'
            $key = Resolve-DshCredential -Provider 'deepinfra'
            $key | Should -Be 'fake-deepinfra-key-abcde'
        }

        It "Resolve-DshCredential throws when no key is configured" {
            { Resolve-DshCredential -Provider 'dsh' } | Should -Throw
        }
    }

    Context "Model slug resolution" {
        It "maps deepseek-v4-flash to the official slug" {
            Resolve-DshModelSlug -Provider 'dsh' -Model 'deepseek-v4-flash' | Should -Be 'deepseek-v4-flash'
        }

        It "maps deepseek-v4-flash to the openrouter slug" {
            Resolve-DshModelSlug -Provider 'openrouter' -Model 'deepseek-v4-flash' | Should -Be 'deepseek/deepseek-v4-flash'
        }

        It "maps deepseek-v4-flash to the deepinfra slug" {
            Resolve-DshModelSlug -Provider 'deepinfra' -Model 'deepseek-v4-flash' | Should -Be 'deepseek-ai/DeepSeek-V4-Flash-0731'
        }

        It "defaults to deepseek-v4-flash when no model is provided" {
            Resolve-DshModelSlug -Provider 'dsh' -Model $null | Should -Be 'deepseek-v4-flash'
        }

        It "rejects an unsupported model" {
            { Resolve-DshModelSlug -Provider 'openrouter' -Model 'not-a-real-model' } | Should -Throw
        }
    }

    Context "Patch file construction" {
        It "writes a YAML patch with the provider-specific model and apiKeyEnv" {
            $tmp = New-DshPatchFile -Provider 'openrouter' -ModelSlug 'deepseek/deepseek-v4-flash'
            $tmp | Should -Exist
            $content = Get-Content -LiteralPath $tmp -Raw
            $content | Should -Match 'apiKeyEnv: DEEPSEEK_API_KEY'
            $content | Should -Match 'id: "deepseek/deepseek-v4-flash"'
            $content | Should -Match 'baseURL: "https://openrouter.ai/api/v1"'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }

        It "writes a YAML patch for the official provider without baseURL" {
            $tmp = New-DshPatchFile -Provider 'dsh' -ModelSlug 'deepseek-v4-flash'
            $tmp | Should -Exist
            $content = Get-Content -LiteralPath $tmp -Raw
            $content | Should -Match 'id: "deepseek-v4-flash"'
            $content | Should -Not -Match 'baseURL:'
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    Context "Command-line argument construction" {
        BeforeEach {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "lane-$(New-Guid)") -Force
            $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "repo-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "plan-$(New-Guid).md"
            '# Test plan' | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            $script:captured = @{ FilePath = $null; ArgumentList = $null }
            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList)
                $script:captured.FilePath = $FilePath
                $script:captured.ArgumentList = $ArgumentList
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }
            Mock Add-PlanPondLog -MockWith { } -ParameterFilter { $true }

            $LanePath = $lane.FullName
            $RepoDir = $repo.FullName
            $Provider = 'openrouter'
            $Model = 'deepseek-v4-flash'
            $Effort = 'max'
            $PlanFiles = @($plan)
            $env:OPENROUTER_API_KEY = 'fake-openrouter-key-67890'
        }

        It "builds dsh --profile headless --patch [file] [prompt] with the mapped openrouter model" {
            $exit = Invoke-DshProvider

            $exit | Should -Be 0
            $args = $script:captured.ArgumentList
            $args | Should -Contain '--profile'
            $args | Should -Contain 'headless'
            $args | Should -Contain '--patch'
            $pIdx = [array]::IndexOf($args, '--patch')
            $args[$pIdx + 1] | Should -BeLike '*.yml'
            $args[-1] | Should -Match 'Implement the following salmon-run plan'
            $script:captured.FilePath | Should -Match 'pwsh|dsh'
        }

        It "sets DEEPSEEK_API_KEY and DEEPSEEK_BASE_URL as process env vars" {
            $env:OPENROUTER_API_KEY = 'secret-openrouter-key-99999'
            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList)
                $script:capturedProcessKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY', 'Process')
                $script:capturedBaseUrl = [Environment]::GetEnvironmentVariable('DEEPSEEK_BASE_URL', 'Process')
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }

            $null = Invoke-DshProvider

            $script:capturedProcessKey | Should -Be 'secret-openrouter-key-99999'
            $script:capturedBaseUrl | Should -Be 'https://openrouter.ai/api/v1'
        }
    }

    Context "Exit-code handling and sentinels" {
        BeforeEach {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "lane-$(New-Guid)") -Force
            $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "repo-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "plan-$(New-Guid).md"
            '# Test plan' | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            Mock Add-PlanPondLog -MockWith { } -ParameterFilter { $true }

            $LanePath = $lane.FullName
            $RepoDir = $repo.FullName
            $Provider = 'openrouter'
            $Model = 'deepseek-v4-flash'
            $Effort = 'max'
            $PlanFiles = @($plan)
            $env:OPENROUTER_API_KEY = 'fake-openrouter-key-67890'
        }

        It "writes .complete and returns 0 on a successful run" {
            Mock Start-Process -MockWith {
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }

            $exit = Invoke-DshProvider

            $exit | Should -Be 0
            Test-Path -LiteralPath (Join-Path $LanePath '.complete') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $LanePath '.failed') | Should -Be $false
        }

        It "writes .failed and returns 1 on a non-zero run" {
            Mock Start-Process -MockWith {
                return [pscustomobject]@{ HasExited = $true; ExitCode = 3; Id = 999 }
            } -ParameterFilter { $true }

            $exit = Invoke-DshProvider

            $exit | Should -Be 1
            Test-Path -LiteralPath (Join-Path $LanePath '.failed') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $LanePath '.complete') | Should -Be $false
        }
    }

    Context "Live DSH plan (skipped unless explicitly enabled with real credentials)" {
        BeforeAll {
            # A real run requires a configured DSH/OpenRouter/DeepInfra key and
            # must never run in CI or unattended. Enable only by setting
            # SALMON_RUN_DSH_LIVE=1 with real credentials configured.
            if ($env:SALMON_RUN_DSH_LIVE -eq '1') {
                # Use the real runtime home for credential resolution.
                $env:SALMON_RUN_HOME = Join-Path $HOME '.salmon'
            }
        }

        It "live DSH plan runs to .complete" -Skip:($env:SALMON_RUN_DSH_LIVE -ne '1') {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "live-lane-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "live-plan-$(New-Guid).md"
            @"
# Live DSH contract plan
**Challenge**: Daily
**Status**: draft

Do not use any tools. Just say exactly "hello from dsh" and exit.
"@ | Set-Content -LiteralPath $plan -Encoding utf8

            $LanePath = $lane.FullName
            $RepoDir = $repoRoot
            $Role = 'coder'
            $Provider = 'openrouter'
            $Model = 'deepseek-v4-flash'
            $Effort = 'max'
            $TimeoutMinutes = 5
            $PlanFiles = @($plan)

            $liveKey = Get-SalmonRunCredential -Name OPENROUTER_API_KEY
            if (-not $liveKey) {
                throw "Could not resolve OPENROUTER_API_KEY from SALMON_RUN_HOME=$env:SALMON_RUN_HOME"
            }
            $env:OPENROUTER_API_KEY = $liveKey

            $exit = Invoke-DshProvider
            $exit | Should -Be 0
            Test-Path -LiteralPath (Join-Path $lane.FullName '.complete') | Should -Be $true
        }
    }
}
