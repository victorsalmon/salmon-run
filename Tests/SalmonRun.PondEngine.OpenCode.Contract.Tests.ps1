#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "OpenCode provider contract" -Tag "Contract", "Regression" {
    BeforeAll {
        $repoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $modulesDir = Join-Path $repoRoot 'Modules'
        $sep = [System.IO.Path]::PathSeparator
        $env:PSModulePath = "$modulesDir$sep$env:PSModulePath"

        $script:OpencodeExecutor = Join-Path $repoRoot 'Modules' 'SalmonRun.PondEngine' 'Executors' 'Opencode.ps1'
        if (-not (Test-Path -LiteralPath $script:OpencodeExecutor)) {
            throw "OpenCode executor not found at $($script:OpencodeExecutor)"
        }

        # Ensure the PlanLog command exists so Write-PlanLog does not try to
        # source it from disk during the test; we mock it below.
        if (-not (Get-Command Add-PlanPondLog -ErrorAction SilentlyContinue)) {
            function Add-PlanPondLog { param($PlanPath, $Entry) }
        }

        # Dot-source the executor so its internal functions (Invoke-OpencodeProvider,
        # Resolve-OpencodeCredential, Get-OpencodeRolePrompt) are available in-scope.
        # Mandatory params are satisfied with throwaway values; the actual values
        # are reassigned per-test before invoking Invoke-OpencodeProvider.
        $dummyLane = Join-Path $TestDrive 'lane'
        $dummyRepo = Join-Path $TestDrive 'repo'
        $dummyPlan = Join-Path $TestDrive 'plan.md'
        . $script:OpencodeExecutor -Role coder -LanePath $dummyLane -RepoDir $dummyRepo -PlanFiles $dummyPlan

        # Use an isolated SALMON_RUN_HOME with an empty .env so the unit tests
        # are not affected by a real ~/.salmon/.env. The live context restores
        # the real home before its run.
        $script:SavedSalmonHome = $env:SALMON_RUN_HOME
        $script:TestSalmonHome = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'salmon-home') -Force
        '' | Set-Content -LiteralPath (Join-Path $script:TestSalmonHome.FullName '.env') -Encoding utf8 -NoNewline
        $env:SALMON_RUN_HOME = $script:TestSalmonHome.FullName

        $script:SavedOpencodeKey = $env:OPENCODE_GO_KEY
    }

    AfterAll {
        if ($null -ne $script:SavedSalmonHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonHome }
        else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }

        if ($null -ne $script:SavedOpencodeKey) { $env:OPENCODE_GO_KEY = $script:SavedOpencodeKey }
        else { Remove-Item Env:\OPENCODE_GO_KEY -ErrorAction SilentlyContinue }
    }

    Context "Credential resolution through SalmonRun.Credentials (never logged)" {
        BeforeEach {
            Remove-Item Env:\OPENCODE_GO_KEY -ErrorAction SilentlyContinue
        }

        AfterEach {
            Remove-Item Env:\OPENCODE_GO_KEY -ErrorAction SilentlyContinue
        }

        It "Resolve-OpencodeCredential returns null when no key is configured" {
            $key = Resolve-OpencodeCredential
            $key | Should -BeNullOrEmpty
        }

        It "Resolve-OpencodeCredential resolves OPENCODE_GO_KEY from the environment" {
            $env:OPENCODE_GO_KEY = 'fake-opencode-go-key-12345'
            $key = Resolve-OpencodeCredential
            $key | Should -Be 'fake-opencode-go-key-12345'
        }

        It "executor does not write the credential into opencode.log" {
            $env:OPENCODE_GO_KEY = 'secret-opencode-go-key-67890'
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "lane-$(New-Guid)") -Force
            $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "repo-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "plan-$(New-Guid).md"
            '# Test plan' | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            $captured = @{ FilePath = $null; ArgumentList = $null }
            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, $NoNewWindow, $PassThru, $ErrorAction)
                $captured.FilePath = $FilePath
                $captured.ArgumentList = $ArgumentList
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }
            Mock Add-PlanPondLog -MockWith { } -ParameterFilter { $true }

            $LanePath = $lane.FullName
            $RepoDir = $repo.FullName
            $Provider = 'opencode-go'
            $Model = 'opencode-go/mimo-v2.5'
            $Effort = 'default'
            $PlanFiles = @($plan)

            $exit = Invoke-OpencodeProvider

            $exit | Should -Be 0
            $logPath = Join-Path $lane.FullName 'opencode.log'
            $logged = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue } else { '' }
            # The credential value must never appear in the log content.
            $logged | Should -Not -Match [regex]::Escape('secret-opencode-go-key-67890')
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
            $PlanFiles = @($plan)
        }

        It "builds 'run <prompt> --model <model> --variant <effort> --auto -f <plan>' for opencode-go/mimo-v2.5" {
            $Provider = 'opencode-go'
            $Model = 'opencode-go/mimo-v2.5'
            $Effort = 'default'

            $exit = Invoke-OpencodeProvider

            $exit | Should -Be 0
            $argList = $script:captured.ArgumentList
            $argList | Should -Contain 'run'
            $argList | Should -Contain '--model'
            $idx = [array]::IndexOf($argList, '--model')
            $argList[$idx + 1] | Should -Be 'opencode-go/mimo-v2.5'
            $argList | Should -Contain '--variant'
            $vidx = [array]::IndexOf($argList, '--variant')
            $argList[$vidx + 1] | Should -Be 'default'
            $argList | Should -Contain '--auto'
            $argList | Should -Contain '-f'
            $fidx = [array]::IndexOf($argList, '-f')
            $argList[$fidx + 1] | Should -Be $plan
        }

        It "defaults the model and effort for opencode-go when omitted" {
            $Provider = 'opencode-go'
            $Model = $null
            $Effort = $null

            $exit = Invoke-OpencodeProvider

            $exit | Should -Be 0
            $argList = $script:captured.ArgumentList
            $idx = [array]::IndexOf($argList, '--model')
            $argList[$idx + 1] | Should -Be 'opencode-go/hy3'
            $vidx = [array]::IndexOf($argList, '--variant')
            $argList[$vidx + 1] | Should -Be 'max'
        }

        It "rejects an unsupported model for opencode-go" {
            $Provider = 'opencode-go'
            $Model = 'opencode-go/not-a-real-model'
            $Effort = 'default'

            { Invoke-OpencodeProvider } | Should -Throw
        }

        It "resolves the Windows CLI to opencode.cmd when present" {
            $Provider = 'opencode-go'
            $Model = 'opencode-go/mimo-v2.5'
            $Effort = 'default'

            $exit = Invoke-OpencodeProvider

            $exit | Should -Be 0
            # On Windows the executor must resolve the .cmd wrapper, not the POSIX shell script.
            if ($IsWindows -or $env:OS -eq 'Windows_NT') {
                # On Windows the resolved CLI may be opencode (if an .exe is in PATH)
                # or the npm opencode.cmd wrapper. It must not be the POSIX shell script.
                $script:captured.FilePath | Should -Match 'opencode(\.cmd|\.exe)?$'
            } else {
                $script:captured.FilePath | Should -Be 'opencode'
            }
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
            $Provider = 'opencode-go'
            $Model = 'opencode-go/mimo-v2.5'
            $Effort = 'default'
            $PlanFiles = @($plan)
        }

        It "writes .complete and returns 0 on a successful run" {
            Mock Start-Process -MockWith {
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }

            $exit = Invoke-OpencodeProvider

            $exit | Should -Be 0
            Test-Path -LiteralPath (Join-Path $LanePath '.complete') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $LanePath '.failed') | Should -Be $false
        }

        It "writes .failed and returns 1 on a non-zero run" {
            Mock Start-Process -MockWith {
                return [pscustomobject]@{ HasExited = $true; ExitCode = 3; Id = 999 }
            } -ParameterFilter { $true }

            $exit = Invoke-OpencodeProvider

            $exit | Should -Be 1
            Test-Path -LiteralPath (Join-Path $LanePath '.failed') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $LanePath '.complete') | Should -Be $false
        }
    }

    Context "Live OpenCode plan (skipped unless explicitly enabled with real credentials)" {
        BeforeAll {
            # A real run requires a configured OPENCODE_GO_KEY and must never run
            # in CI or unattended. Enable only by setting SALMON_RUN_OPENCODE_LIVE=1
            # with real credentials configured.
            if ($env:SALMON_RUN_OPENCODE_LIVE -eq '1') {
                # Use the real runtime home for credential resolution.
                # Do not trust the saved value; it may be a stale Pester temp path.
                $env:SALMON_RUN_HOME = Join-Path $HOME '.salmon'
            }
        }

        It "live OpenCode plan runs to .complete" -Skip:($env:SALMON_RUN_OPENCODE_LIVE -ne '1') {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "live-lane-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "live-plan-$(New-Guid).md"
            @"
# Live OpenCode contract plan
**Challenge**: Daily
**Status**: draft

Do not use any tools. Just say exactly "hello from opencode" and exit.
"@ | Set-Content -LiteralPath $plan -Encoding utf8

            $LanePath = $lane.FullName
            $RepoDir = $repoRoot
            $Role = 'coder'
            $Provider = 'opencode-go'
            $Model = 'opencode-go/mimo-v2.5'
            $Effort = 'default'
            $TimeoutMinutes = 5
            $PlanFiles = @($plan)

            # Resolve the live credential from the real SALMON_RUN_HOME and set
            # it explicitly. The executor also resolves, but this guarantees the
            # child process has the key even if the resolver path behaves
            # differently under Pester scoping.
            $liveKey = Get-SalmonRunCredential -Name OPENCODE_GO_KEY
            if (-not $liveKey) {
                throw "Could not resolve OPENCODE_GO_KEY from SALMON_RUN_HOME=$env:SALMON_RUN_HOME"
            }
            $env:OPENCODE_GO_KEY = $liveKey

            $exit = Invoke-OpencodeProvider
            $exit | Should -Be 0
            Test-Path -LiteralPath (Join-Path $lane.FullName '.complete') | Should -Be $true
        }
    }

    Context "Windows POSIX tool availability" -Tag "OpenCode", "Contract", "Windows" {
        It "Resolve-OpencodeWindowsToolPath finds Git for Windows POSIX tools on Windows" -Skip:($IsLinux -or $IsMacOS -or -not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
            $toolPath = Resolve-OpencodeWindowsToolPath
            $toolPath | Should -Not -BeNullOrEmpty
            $toolPath | Should -Match ([regex]::Escape('Git\usr\bin'))
            $toolPath | Should -Match ([regex]::Escape('Git\bin'))
        }

        It "Invoke-OpencodeProvider prepends POSIX tools to the child PATH on Windows" -Skip:($IsLinux -or $IsMacOS -or -not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
            $lane = New-Item -ItemType Directory -Path (Join-Path $TestDrive "path-lane-$(New-Guid)") -Force
            $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive "path-repo-$(New-Guid)") -Force
            $plan = Join-Path $TestDrive "path-plan-$(New-Guid).md"
            '# Test plan' | Set-Content -LiteralPath $plan -Encoding utf8 -NoNewline

            $captured = @{ Env = $null }
            Mock Start-Process -MockWith {
                param($FilePath, $ArgumentList, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError, $NoNewWindow, $PassThru, $ErrorAction)
                $captured.Env = $env:PATH
                return [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 999 }
            } -ParameterFilter { $true }
            Mock Add-PlanPondLog -MockWith { } -ParameterFilter { $true }

            $LanePath = $lane.FullName
            $RepoDir = $repo.FullName
            $Provider = 'opencode-go'
            $Model = 'opencode-go/mimo-v2.5'
            $Effort = 'default'
            $PlanFiles = @($plan)

            $null = Invoke-OpencodeProvider

            $captured.Env | Should -Match ([regex]::Escape('Git\usr\bin'))
            $captured.Env | Should -Match ([regex]::Escape('Git\bin'))
            # Git's POSIX find must come before Windows' find.exe
            $idxUsrBin = $captured.Env.IndexOf('\Git\usr\bin')
            $idxSystem32 = $captured.Env.IndexOf('\System32')
            if ($idxSystem32 -ge 0) {
                $idxUsrBin | Should -BeLessThan $idxSystem32
            }
        }
    }
}

