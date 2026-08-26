#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Load the modules at the file scope so Pester can resolve InModuleScope during
# discovery and the path-override environment variables take effect immediately.
$__moduleDir = $PSScriptRoot
$__pathsPsd1 = Join-Path $__moduleDir '..' 'Modules' 'SalmonRun.Paths' 'SalmonRun.Paths.psd1'
$__diagPs1 = Join-Path $__moduleDir '..' 'Modules' 'SalmonRun.Diagnostics' 'SalmonRun.Diagnostics.ps1'
if (Test-Path $__pathsPsd1) { Import-Module -Name $__pathsPsd1 -Force -DisableNameChecking }
if (Test-Path $__diagPs1) { . $__diagPs1 }

Describe "SalmonRun.Diagnostics Module FunctionsToExport" -Tag "Diagnostics", "Regression-Only" {
    It "exports the 4 expected functions" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport
        $exports | Should -Contain "Write-SetupLog"
        $exports | Should -Contain "Test-Step"
        $exports | Should -Contain "Get-ReportsDir"
        $exports | Should -Contain "Get-DeliverablesDir"
        $exports.Count | Should -Be 4
    }
}

Describe "SalmonRun.Diagnostics Module" -Tag "Diagnostics" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        . $modulePath

        $pathsPsd1 = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.psd1'
        try { Import-Module -Name $pathsPsd1 -Force -ErrorAction Stop } catch { try { . (Join-Path $PSScriptRoot '..\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1') } catch { } }

        $corePath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        try { . $corePath } catch { Write-Debug "Core module load skipped: $_" }
        $statePath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.State.ps1'
        try { . $statePath } catch { Write-Debug "Core state load skipped: $_" }

        $script:TestTempDir = Join-Path $env:TEMP "SalmonRun-DiagnosticsTests-$(Get-Random)"
        if ($script:TestTempDir) {
            New-Item -ItemType Directory -Path $script:TestTempDir -Force | Out-Null
        }

        $script:SavedInterclawSetupLog = $env:INTERCLAW_SETUP_LOG
        $script:SavedInterclawLogLevel = $env:INTERCLAW_LOG_LEVEL
        $script:SavedInterclawLogFormat = $env:INTERCLAW_LOG_FORMAT
        $script:SavedInterclawRunId = $env:INTERCLAW_RUN_ID
        $script:SavedUserProfile = $env:USERPROFILE
        $script:SavedHome = $env:HOME
        $script:SavedRepoRoot = $env:REPO_ROOT
        $script:SavedRepoDir = $env:REPO_DIR
    }

    AfterAll {
        if ($script:TestTempDir -and (Test-Path $script:TestTempDir)) {
            Remove-Item -Recurse -Force $script:TestTempDir
        }

        if ($script:SavedInterclawSetupLog) { $env:INTERCLAW_SETUP_LOG = $script:SavedInterclawSetupLog } else { Remove-Item Env:\INTERCLAW_SETUP_LOG -ErrorAction SilentlyContinue }
        if ($script:SavedInterclawLogLevel) { $env:INTERCLAW_LOG_LEVEL = $script:SavedInterclawLogLevel } else { Remove-Item Env:\INTERCLAW_LOG_LEVEL -ErrorAction SilentlyContinue }
        if ($script:SavedInterclawLogFormat) { $env:INTERCLAW_LOG_FORMAT = $script:SavedInterclawLogFormat } else { Remove-Item Env:\INTERCLAW_LOG_FORMAT -ErrorAction SilentlyContinue }
        if ($script:SavedInterclawRunId) { $env:INTERCLAW_RUN_ID = $script:SavedInterclawRunId } else { Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue }
        if ($script:SavedUserProfile) { $env:USERPROFILE = $script:SavedUserProfile } else { Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue }
        if ($script:SavedHome) { $env:HOME = $script:SavedHome } else { Remove-Item Env:\HOME -ErrorAction SilentlyContinue }
        if ($script:SavedRepoRoot) { $env:REPO_ROOT = $script:SavedRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
        if ($script:SavedRepoDir) { $env:REPO_DIR = $script:SavedRepoDir } else { Remove-Item Env:\REPO_DIR -ErrorAction SilentlyContinue }
    }

    Context "Write-SetupLog" -Tag "Diagnostics" {
        BeforeEach {
            $env:INTERCLAW_SETUP_LOG = Join-Path $script:TestTempDir "test.log"
            if (Test-Path $env:INTERCLAW_SETUP_LOG) { Remove-Item $env:INTERCLAW_SETUP_LOG }
        }

        It "appends a timestamped INFO entry to the log file" {
            Write-SetupLog -Message "Test message"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $content | Should -Match "\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}( \[[^\]]+\])? \[INFO\] Test message"
        }

        It "silently skips logging when INTERCLAW_SETUP_LOG is not set" {
            $env:INTERCLAW_SETUP_LOG = $null
            { Write-SetupLog -Message "Should not fail" } | Should -Not -Throw
        }

        It "appends entry with custom level" {
            Write-SetupLog -Message "Warning message" -Level "WARN"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $content | Should -Match "\[WARN\] Warning message"
        }

        It "includes RunId when INTERCLAW_RUN_ID is set" {
            $env:INTERCLAW_RUN_ID = "abc12345"
            Write-SetupLog -Message "RunId test"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $content | Should -Match "\[abc12345\] \[INFO\] RunId test"
            Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue
        }

        It "outputs JSON when INTERCLAW_LOG_FORMAT is json" {
            $env:INTERCLAW_LOG_FORMAT = "json"
            $env:INTERCLAW_RUN_ID = "def67890"
            Write-SetupLog -Message "JSON test"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $parsed = $content | ConvertFrom-Json
            $parsed.level | Should -Be "INFO"
            $parsed.message | Should -Be "JSON test"
            $parsed.runId | Should -Be "def67890"
            Remove-Item Env:\INTERCLAW_LOG_FORMAT -ErrorAction SilentlyContinue
            Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue
        }

        It "includes agent and phase metadata in JSON format" {
            $env:INTERCLAW_LOG_FORMAT = "json"
            Write-SetupLog -Message "Agent test" -Agent "pester-agent" -Phase "testing"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $parsed = $content | ConvertFrom-Json
            $parsed.agent | Should -Be "pester-agent"
            $parsed.phase | Should -Be "testing"
            Remove-Item Env:\INTERCLAW_LOG_FORMAT -ErrorAction SilentlyContinue
        }

        It "filters DEBUG entries when INTERCLAW_LOG_LEVEL is INFO" {
            $env:INTERCLAW_LOG_LEVEL = "INFO"
            Write-SetupLog -Message "Debug message" -Level "DEBUG"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw -ErrorAction SilentlyContinue
            $content | Should -BeNullOrEmpty
            Remove-Item Env:\INTERCLAW_LOG_LEVEL -ErrorAction SilentlyContinue
        }

        It "allows DEBUG entries when INTERCLAW_LOG_LEVEL is DEBUG" {
            $env:INTERCLAW_LOG_LEVEL = "DEBUG"
            Write-SetupLog -Message "Debug allowed" -Level "DEBUG"
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $content | Should -Match "\[DEBUG\] Debug allowed"
            Remove-Item Env:\INTERCLAW_LOG_LEVEL -ErrorAction SilentlyContinue
        }
    }

    Context "Write-SetupLog mutex safety" -Tag "Diagnostics", "Regression-Only" {
        BeforeEach {
            $env:INTERCLAW_SETUP_LOG = Join-Path $script:TestTempDir "mutex-test.log"
            if (Test-Path $env:INTERCLAW_SETUP_LOG) { Remove-Item $env:INTERCLAW_SETUP_LOG }
        }

        It "does not throw when mutex is available" {
            { Write-SetupLog -Message "Mutex available test" } | Should -Not -Throw
            $content = Get-Content $env:INTERCLAW_SETUP_LOG -Raw
            $content | Should -Match "\[INFO\] Mutex available test"
        }

        It "releases mutex after writing" {
            Write-SetupLog -Message "Release test"
            $mtx = New-Object System.Threading.Mutex($false, "Global\SalmonRun-SetupLog-Mutex")
            $acquired = $false
            try {
                $acquired = $mtx.WaitOne(0)
                $acquired | Should -Be $true
            } finally {
                if ($acquired) { try { $mtx.ReleaseMutex() } catch { } }
                $mtx.Dispose()
            }
        }

        It "handles concurrent writes without corruption" {
            $logPath = $env:INTERCLAW_SETUP_LOG
            $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'

            1..4 | ForEach-Object -Parallel {
                . $using:modulePath
                $env:INTERCLAW_SETUP_LOG = $using:logPath
                Write-SetupLog -Message "Concurrent message $_"
            }

            $content = Get-Content $env:INTERCLAW_SETUP_LOG
            $content.Count | Should -Be 4
            $content | ForEach-Object { $_ | Should -Match "\[INFO\] Concurrent message [1-4]" }
        }
    }

    InModuleScope 'SalmonRun.Diagnostics' {
        Context "Test-Step" -Tag "Diagnostics" {
            BeforeEach {
                $script:FailCount = 0
                $script:Results = @()
                Mock Write-Host {}
            }

            It "records a passing result" {
                Test-Step -Name "Check A" -Passed $true
                $script:FailCount | Should -Be 0
                $script:Results.Count | Should -Be 1
                $script:Results[0].Name | Should -Be "Check A"
                $script:Results[0].Passed | Should -Be $true
            }

            It "records a failing result and increments fail counter" {
                Test-Step -Name "Check B" -Passed $false -Detail "Detail here" -Remediation "Fix it"
                $script:FailCount | Should -Be 1
                $script:Results.Count | Should -Be 1
                $script:Results[0].Passed | Should -Be $false
                $script:Results[0].Detail | Should -Be "Detail here"
                $script:Results[0].Remediation | Should -Be "Fix it"
            }

            It "writes PASS in green and FAIL in red" {
                Test-Step -Name "PassCheck" -Passed $true
                Should -Invoke Write-Host -ParameterFilter { $Object -match '\[PASS\]' -and $ForegroundColor -eq 'Green' } -Exactly 1 -Scope It

                Test-Step -Name "FailCheck" -Passed $false
                Should -Invoke Write-Host -ParameterFilter { $Object -match '\[FAIL\]' -and $ForegroundColor -eq 'Red' } -Exactly 1 -Scope It
            }
        }
    }

    Context "Get-ReportsDir" -Tag "Diagnostics" {
        BeforeAll {
            $script:FakeRepoRoot = Join-Path $script:TestTempDir "FakeRepo"
            $script:SavedReportsHome = $env:HOME
            $script:SavedReportsRepoRoot = $env:REPO_ROOT
            $env:HOME = $script:TestTempDir
            $env:REPO_ROOT = $script:FakeRepoRoot
        }

        AfterAll {
            if ($script:SavedReportsHome) { $env:HOME = $script:SavedReportsHome } else { Remove-Item Env:\HOME -ErrorAction SilentlyContinue }
            if ($script:SavedReportsRepoRoot) { $env:REPO_ROOT = $script:SavedReportsRepoRoot } else { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue }
        }

        It "returns container path when it exists" {
            if (Test-Path "/home/node/.ORCHESTRATOR/workspace/reports") {
                $path = Get-ReportsDir
                $path | Should -Be "/home/node/.ORCHESTRATOR/workspace/reports"
            }
        }

        It "creates and returns host path when container path does not exist" {
            $expected = Join-Path (Join-Path $script:FakeRepoRoot "Tasks") "Logs"
            $path = Get-ReportsDir
            $path | Should -Be $expected
            Test-Path $expected | Should -Be $true
            if (Test-Path $expected) { Remove-Item -Recurse -Force $expected -ErrorAction SilentlyContinue }
        }

        It "returns existing host path without creating it twice" {
            $expected = Join-Path (Join-Path $script:FakeRepoRoot "Tasks") "Logs"
            if (-not (Test-Path $expected)) { New-Item -ItemType Directory -Path $expected -Force | Out-Null }
            $path1 = Get-ReportsDir
            $path2 = Get-ReportsDir
            $path2 | Should -Be $path1
            if (Test-Path $expected) { Remove-Item -Recurse -Force $expected -ErrorAction SilentlyContinue }
        }
    }

    Context "Get-DeliverablesDir" -Tag "Diagnostics" {
        BeforeAll {
            $script:DeliverablesTestDir = Join-Path $script:TestTempDir "DeliverablesTest"
            New-Item -ItemType Directory -Path $script:DeliverablesTestDir -Force | Out-Null
            $script:SavedUserProfile = $env:USERPROFILE
            Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
            $script:SavedHome = $env:HOME
            $env:HOME = $script:DeliverablesTestDir
            if (Get-Command 'Get-HomeDir' -ErrorAction SilentlyContinue) {
                Reset-InterclawPathCache
            }
            if (-not (Get-Command 'Get-HomeDir' -ErrorAction SilentlyContinue)) {
                function Get-HomeDir { $env:HOME }
            }
        }

        AfterAll {
            if ($script:SavedUserProfile) { $env:USERPROFILE = $script:SavedUserProfile }
            if ($script:SavedHome) { $env:HOME = $script:SavedHome }
            if (Get-Command 'Get-HomeDir' -ErrorAction SilentlyContinue) {
                Reset-InterclawPathCache
            }
        }

        AfterEach {
            $childDirs = Get-ChildItem -Path $script:DeliverablesTestDir -Directory -ErrorAction SilentlyContinue
            foreach ($d in $childDirs) {
                Remove-Item -Recurse -Force $d.FullName -ErrorAction SilentlyContinue
            }
        }

        It "creates deliverables folder on first call" {
            $containerPath = "/home/node/.ORCHESTRATOR/workspace/deliverables"
            if (Test-Path $containerPath) {
                Set-ItResult -Skipped -Because "container path exists"
            } else {
                $path = Get-DeliverablesDir
                $path | Should -Be (Join-Path (Join-Path (Join-Path $script:DeliverablesTestDir ".ORCHESTRATOR") "workspace") "deliverables")
                Test-Path $path | Should -Be $true
            }
        }

        It "creates Trash subfolder inside deliverables" {
            $containerPath = "/home/node/.ORCHESTRATOR/workspace/deliverables"
            if (Test-Path $containerPath) {
                Set-ItResult -Skipped -Because "container path exists"
            } else {
                $path = Get-DeliverablesDir
                $trashPath = Join-Path $path "Trash"
                Test-Path $trashPath | Should -Be $true
            }
        }

        It "returns existing path without errors on second call" {
            $containerPath = "/home/node/.ORCHESTRATOR/workspace/deliverables"
            if (Test-Path $containerPath) {
                Set-ItResult -Skipped -Because "container path exists"
            } else {
                $path1 = Get-DeliverablesDir
                $path2 = Get-DeliverablesDir
                $path2 | Should -Be $path1
            }
        }

        It "returns container path when /home/node/.ORCHESTRATOR/workspace/deliverables exists" {
            $containerPath = "/home/node/.ORCHESTRATOR/workspace/deliverables"
            if (Test-Path $containerPath) {
                $path = Get-DeliverablesDir
                $path | Should -Be $containerPath
            }
        }

        It "does not throw when USERPROFILE is not set" {
            Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
            $env:HOME = $script:DeliverablesTestDir
            { $path = Get-DeliverablesDir } | Should -Not -Throw
            $env:USERPROFILE = $script:DeliverablesTestDir
            Remove-Item Env:\HOME -ErrorAction SilentlyContinue
        }
    }
}
