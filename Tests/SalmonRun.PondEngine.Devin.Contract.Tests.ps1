#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "Devin provider contract" -Tag "Contract", "Regression" {
    BeforeAll {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $modulesDir = Join-Path $repoRoot 'Modules'
        $sep = [System.IO.Path]::PathSeparator
        $env:PSModulePath = "$modulesDir$sep$env:PSModulePath"

        $script:DevinExecutor = Join-Path $repoRoot 'Modules' 'SalmonRun.PondEngine' 'Executors' 'Devin.ps1'
        if (-not (Test-Path -LiteralPath $script:DevinExecutor)) {
            throw "Devin executor not found at $($script:DevinExecutor)"
        }

        # Ensure the PlanLog command exists so Write-PlanLog does not try to
        # source it from disk during the test; we mock it below.
        if (-not (Get-Command Add-PlanPondLog -ErrorAction SilentlyContinue)) {
            function Add-PlanPondLog { param($PlanPath, $Entry) }
        }

        # Dot-source the executor so its internal functions (Invoke-DevinProvider,
        # Resolve-DevinCredential, Get-DevinRolePrompt, New-DevinPromptFile) are
        # available in-scope. Mandatory params are satisfied with throwaway
        # values; the actual values are reassigned per-test before invoking
        # Invoke-DevinProvider.
        $dummyLane = Join-Path $TestDrive 'lane'
        $dummyRepo = Join-Path $TestDrive 'repo'
        $dummyPlan = Join-Path $TestDrive 'plan.md'
        . $script:DevinExecutor -Role coder -LanePath $dummyLane -RepoDir $dummyRepo -PlanFiles $dummyPlan

        # Use an isolated SALMON_RUN_HOME with an empty .env so the unit tests
        # are not affected by a real ~/.salmon/.env. The live context restores
        # the real home before its run.
        $script:SavedSalmonHome = $env:SALMON_RUN_HOME
        $script:TestSalmonHome = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'salmon-home') -Force
        '' | Set-Content -LiteralPath (Join-Path $script:TestSalmonHome.FullName '.env') -Encoding utf8 -NoNewline
        $env:SALMON_RUN_HOME = $script:TestSalmonHome.FullName

        $script:SavedDevinKey = $env:DEVIN_API_KEY
    }

    AfterAll {
        if ($null -ne $script:SavedSalmonHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonHome }
        else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }

        if ($null -ne $script:SavedDevinKey) { $env:DEVIN_API_KEY = $script:SavedDevinKey }
        else { Remove-Item Env:\DEVIN_API_KEY -ErrorAction SilentlyContinue }
    }

    Context "Credential resolution through SalmonRun.Credentials (never logged)" {
        BeforeEach {
            Remove-Item Env:\DEVIN_API_KEY -ErrorAction SilentlyContinue
        }

        AfterEach {
            Remove-Item Env:\DEVIN_API_KEY -ErrorAction SilentlyContinue
        }

        It "Resolve-DevinCredential throws when no key is configured" {
            # When neither SalmonRun.Credentials nor the environment provides a
            # key, the executor must surface a clear error rather than run blind.
            { Resolve-DevinCredential } | Should -Throw
        }

        It "Resolve-DevinCredential resolves DEVIN_API_KEY from the environment" {
            $env:DEVIN_API_KEY = 'fake-devin-api-key-12345'
            $key = Resolve-DevinCredential
            $key | Should -Be 'fake-devin-api-key-12345'
        }
    }

    Context "Command-line argument construction" {
        BeforeEach {
            $env:DEVIN_API_KEY = 'fake-devin-api-key-12345'

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
            $Provider = 'devin'
            $PlanFiles = @($plan)
        }

        It "builds 'devin --prompt-file <file> -p --model swe-1-7' for the default model" {
            $Model = $null
            $Effort = $null

            $exit = Invoke-DevinProvider

            $exit | Should -Be 0
            $argList = $script:captured.ArgumentList
            $argList | Should -Contain '--prompt-file'
            $pIdx = [array]::IndexOf($argList, '--prompt-file')
            # the prompt file argument must be the generated temp file
            $argList[$pIdx + 1] | Should -Not -BeNullOrEmpty
            $argList | Should -Contain '-p'
            $argList | Should -Contain '--model'
            $mIdx = [array]::IndexOf($argList, '--model')
            $argList[$mIdx + 1] | Should -Be 'swe-1-7'
        }

        It "uses the explicit model when provided" {
            $Model = 'swe-1-7'
            $Effort = 'max'

            $exit = Invoke-DevinProvider

            $exit | Should -Be 0
            $argList = $script:captured.ArgumentList
            $mIdx = [array]::IndexOf($argList, '--model')
            $argList[$mIdx + 1] | Should -Be 'swe-1-7'
        }

        It "resolves the devin CLI from PATH" {
            $Model = 'swe-1-7'
            $Effort = 'medium'

            $exit = Invoke-DevinProvider

            $exit | Should -Be 0
            # On Windows the CLI is devin.exe; Start-Process resolves 'devin'
            # through PATH. The FilePath must reference the devin executable.
            $script:captured.FilePath | Should -BeLike '*devin*'
        }
    }

    Context "Exit-code handling and sentinels" {
        BeforeEach {
            $env:DEVIN_API_KEY = 'fake-devin-api-key-12345'

            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "lane-$(New-Guid)") -Force
            $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "repo-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "plan-$(New-Guid).md"
            '# Test plan' | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            Mock Add-PlanPondLog -MockWith { } -ParameterFilter { $true }

            $LanePath = $lane.FullName
            $RepoDir = $repo.FullName
            $Provider = 'devin'
            $Model = 'swe-1-7'
            $Effort = 'medium'
            $PlanFiles = @($plan)
        }

        It "writes .complete and returns 0 on a successful run" {
            Mock Start-Process -MockWith {
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }

            $exit = Invoke-DevinProvider

            $exit | Should -Be 0
            Test-Path -LiteralPath (Join-Path $LanePath '.complete') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $LanePath '.failed') | Should -Be $false
        }

        It "writes .failed and returns 1 on a non-zero run" {
            Mock Start-Process -MockWith {
                return [pscustomobject]@{ HasExited = $true; ExitCode = 3; Id = 999 }
            } -ParameterFilter { $true }

            $exit = Invoke-DevinProvider

            $exit | Should -Be 1
            Test-Path -LiteralPath (Join-Path $LanePath '.failed') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $LanePath '.complete') | Should -Be $false
        }
    }

    Context "Credential is set as a process env var and not logged" {
        BeforeEach {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "lane-$(New-Guid)") -Force
            $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "repo-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "plan-$(New-Guid).md"
            '# Test plan' | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, $NoNewWindow, $PassThru, $ErrorAction)
                # capture whether the key was exposed as a process env var
                $script:capturedProcessKey = [Environment]::GetEnvironmentVariable('DEVIN_API_KEY', 'Process')
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }
            Mock Add-PlanPondLog -MockWith { } -ParameterFilter { $true }

            $LanePath = $lane.FullName
            $RepoDir = $repo.FullName
            $Provider = 'devin'
            $Model = 'swe-1-7'
            $Effort = 'medium'
            $PlanFiles = @($plan)
        }

        It "exposes DEVIN_API_KEY to the devin process and never writes it to devin.log" {
            $secret = 'secret-devin-api-key-67890'
            $env:DEVIN_API_KEY = $secret

            $exit = Invoke-DevinProvider

            $exit | Should -Be 0
            # The credential must be set as a process-scoped environment variable
            # so the spawned devin CLI can read it.
            $script:capturedProcessKey | Should -Be $secret
            $logPath = Join-Path $lane.FullName 'devin.log'
            $logged = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue } else { '' }
            $logged | Should -Not -Match [regex]::Escape($secret)
        }
    }

    Context "Live Devin plan (skipped unless explicitly enabled with real credentials)" {
        BeforeAll {
            # A real run requires a configured DEVIN_API_KEY and must never run
            # in CI or unattended. Enable only by setting SALMON_RUN_DEVIN_LIVE=1
            # with real credentials configured.
            if ($env:SALMON_RUN_DEVIN_LIVE -eq '1') {
                # Use the real runtime home for credential resolution.
                $env:SALMON_RUN_HOME = Join-Path $HOME '.salmon'
            }
        }

        It "live Devin plan runs to .complete" -Skip:($env:SALMON_RUN_DEVIN_LIVE -ne '1') {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "live-lane-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "live-plan-$(New-Guid).md"
            @"
# Live Devin contract plan
**Challenge**: Daily
**Status**: draft

Do not use any tools. Just say exactly "hello from devin" and exit.
"@ | Set-Content -LiteralPath $plan -Encoding utf8

            $LanePath = $lane.FullName
            $RepoDir = $repoRoot
            $Role = 'coder'
            $Provider = 'devin'
            $Model = 'swe-1-7'
            $Effort = 'medium'
            $TimeoutMinutes = 5
            $PlanFiles = @($plan)

            $liveKey = Get-SalmonRunCredential -Name DEVIN_API_KEY
            if (-not $liveKey) {
                throw "Could not resolve DEVIN_API_KEY from SALMON_RUN_HOME=$env:SALMON_RUN_HOME"
            }
            $env:DEVIN_API_KEY = $liveKey

            $exit = Invoke-DevinProvider
            $exit | Should -Be 0
            Test-Path -LiteralPath (Join-Path $lane.FullName '.complete') | Should -Be $true
        }
    }
}

