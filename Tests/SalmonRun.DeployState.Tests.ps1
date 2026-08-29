#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

Describe "SalmonRun.DeployState Module FunctionsToExport" -Tag "DeployState", "Regression-Only" {
    It "exports the 9 expected functions" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.DeployState\SalmonRun.DeployState.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport
        $exports | Should -Contain "Add-SetupError"
        $exports | Should -Contain "Export-SetupErrors"
        $exports | Should -Contain "Set-SetupCheckpoint"
        $exports | Should -Contain "Test-SetupCheckpoint"
        $exports | Should -Contain "Clear-SetupCheckpoints"
        $exports | Should -Contain "New-SetupErrorsTasksFile"
        $exports | Should -Contain "Invoke-DeployStatePhase"
        $exports | Should -Contain "Invoke-CredentialCleanup"
        $exports | Should -Contain "Clear-DeployState"
    }
}

Describe "SalmonRun.DeployState Module" -Tag "DeployState" {
    BeforeAll {
        # Stub dependencies that the extracted functions rely on
        $script:TestTempDir = Join-Path $env:TEMP "Interclaw-DeployStateTests-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:TestTempDir -Force | Out-Null

        $script:TestRepoRoot = Join-Path $script:TestTempDir "repo"
        $script:TestHomeDir = Join-Path $script:TestTempDir "home"
        $null = New-Item -ItemType Directory -Path $script:TestRepoRoot -Force
        $null = New-Item -ItemType Directory -Path $script:TestHomeDir -Force

        # Stub forwarder dependencies
        function global:Get-HomeDir { $script:TestHomeDir }
        function global:Get-SalmonHome { $script:TestHomeDir }
        function global:Get-SalmonTaskRoot { $script:TestHomeDir }
        function global:Get-InterclawRepoRoot { $script:TestRepoRoot }
        function global:Get-ReportsDir {
            $d = Join-Path (Join-Path $script:TestRepoRoot "Tasks") "Logs"
            $null = New-Item -ItemType Directory -Path $d -Force
            return $d
        }
        $script:LastLogMessage = $null
        function global:Write-SetupLog {
            param([string]$Message, [string]$Level = "INFO")
            $script:LastLogMessage = $Message
        }

        # Stub Core dependency (Write-AtomicJson)
        function global:Write-AtomicJson {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Path,
                [Parameter(Mandatory, ValueFromPipeline)]
                $InputObject,
                [int]$Depth = 3,
                [switch]$Compress,
                [switch]$NoNewline
            )
            begin { $script:WajObjects = [System.Collections.Generic.List[object]]::new() }
            process { $script:WajObjects.Add($InputObject) }
            end {
                $json = $script:WajObjects | ConvertTo-Json -Depth $Depth -Compress:$Compress
                if ($NoNewline) { Set-Content -Path $Path -Value $json -Encoding UTF8 -NoNewline }
                else { Set-Content -Path $Path -Value $json -Encoding UTF8 }
                $script:LastWajPath = $Path
            }
        }

        # Stub Core dependency (Write-AtomicFile)
        function global:Write-AtomicFile {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)]
                [string]$Path,
                [Parameter(Mandatory, ValueFromPipeline)]
                [string]$Value,
                [string]$Encoding = "UTF8"
            )
            end {
                $Value | Set-Content -Path $Path -Encoding $Encoding
            }
        }

        # Preserve env vars
        $script:SavedRunId = $env:INTERCLAW_RUN_ID
        $env:INTERCLAW_RUN_ID = "test-run-001"

        # Load the module under test
        $modulePath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.DeployState\SalmonRun.DeployState.ps1'
        . $modulePath
    }

    AfterAll {
        if (Test-Path $script:TestTempDir) {
            Remove-Item -Recurse -Force $script:TestTempDir
        }
        if ($script:SavedRunId) { $env:INTERCLAW_RUN_ID = $script:SavedRunId } else { Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue }

        $globalStubs = @('Get-HomeDir','Get-InterclawRepoRoot','Get-ReportsDir','Write-SetupLog','Write-AtomicJson','Write-AtomicFile')
        foreach ($stub in $globalStubs) {
            if (Get-Item -Path "function:\$stub" -ErrorAction SilentlyContinue) {
                Remove-Item -Path "function:\$stub" -Force -ErrorAction SilentlyContinue
            }
        }
    }

    BeforeEach {
        Clear-DeployState
        $script:LastLogMessage = $null
    }

    Context "Add-SetupError" -Tag "DeployState" {
        It "records a fatal error to the internal list" {
            $entry = InModuleScope -ModuleName 'SalmonRun.DeployState' -ScriptBlock {
                Clear-DeployState
                Add-SetupError -Phase "Phase1" -Message "Something went wrong" -Category "AWS"
                return $script:InterclawErrors[0]
            }
            $entry | Should -Not -BeNullOrEmpty
            $entry.Phase | Should -Be "Phase1"
            $entry.Message | Should -Be "Something went wrong"
            $entry.Category | Should -Be "AWS"
            $entry.Recoverable | Should -Be $false
            $entry.Timestamp | Should -Not -BeNullOrEmpty
        }

        It "records a recoverable error" {
            $entry = InModuleScope -ModuleName 'SalmonRun.DeployState' -ScriptBlock {
                Clear-DeployState
                Add-SetupError -Phase "Phase2" -Message "Recoverable issue" -Recoverable $true
                return $script:InterclawErrors[0]
            }
            $entry | Should -Not -BeNullOrEmpty
            $entry.Recoverable | Should -Be $true
        }

        It "defaults category to 'Phase'" {
            $entry = InModuleScope -ModuleName 'SalmonRun.DeployState' -ScriptBlock {
                Clear-DeployState
                Add-SetupError -Phase "Test" -Message "No category"
                return $script:InterclawErrors[0]
            }
            $entry.Category | Should -Be "Phase"
        }

        It "logs fatal errors at ERROR level" {
            Add-SetupError -Phase "Test" -Message "Fatal error"
            $script:LastLogMessage | Should -Match "\[Test\] FATAL:"
        }

        It "logs recoverable errors at WARN level" {
            Add-SetupError -Phase "Test" -Message "Recoverable issue" -Recoverable $true
            $script:LastLogMessage | Should -Match "\[Test\] RECOVERABLE:"
        }
    }

    Context "Export-SetupErrors" -Tag "DeployState" {
        It "returns silently when no errors exist" {
            Export-SetupErrors | Should -BeNullOrEmpty
        }

        It "generates a valid markdown report with errors" {
            Add-SetupError -Phase "Phase1" -Message "Error 1"
            Add-SetupError -Phase "Phase1" -Message "Error 2" -Recoverable $true
            (Get-Module -Name SalmonRun.DeployState).SessionState.PSVariable.GetValue('SetupPhasesCompleted').Add("Phase1")
            Export-SetupErrors

            $files = Get-ChildItem -Path (Get-ReportsDir) -Filter "*setup-errors*" -ErrorAction SilentlyContinue
            $files.Count | Should -BeGreaterThan 0
        }

        It "includes a deferred tasks section for recoverable errors" {
            Add-SetupError -Phase "Phase1" -Message "Recoverable item" -Recoverable $true
            Export-SetupErrors

            $files = Get-ChildItem -Path (Get-ReportsDir) -Filter "*setup-errors*" -ErrorAction SilentlyContinue
            $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $content = Get-Content $latest.FullName -Raw
            $content | Should -Match "Deferred Human Tasks"
        }
    }

    Context "Set-SetupCheckpoint" -Tag "DeployState" {
        AfterEach {
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            if (Test-Path $checkpointFile) { Remove-Item $checkpointFile -Force }
        }

        It "writes a checkpoint to checkpoints.json" {
            Set-SetupCheckpoint -Name "Phase1"
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            Test-Path $checkpointFile | Should -Be $true
        }

        It "stores the checkpoint under the current run ID" {
            Set-SetupCheckpoint -Name "Phase1"
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            $raw = Get-Content $checkpointFile -Raw | ConvertFrom-Json
            $data = ConvertFrom-PSCustomObjectToHashtable $raw
            $data.ContainsKey("test-run-001") | Should -Be $true
            $data["test-run-001"].ContainsKey("Phase1") | Should -Be $true
            $data["test-run-001"]["Phase1"].Status | Should -Be "complete"
        }

        It "silently returns when INTERCLAW_RUN_ID is empty" {
            $saved = $env:INTERCLAW_RUN_ID
            $env:INTERCLAW_RUN_ID = ""
            { Set-SetupCheckpoint -Name "Phase1" } | Should -Not -Throw
            $env:INTERCLAW_RUN_ID = $saved
        }
    }

    Context "Test-SetupCheckpoint" -Tag "DeployState" {
        AfterEach {
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            if (Test-Path $checkpointFile) { Remove-Item $checkpointFile -Force }
        }

        It "returns true when checkpoint exists" {
            Set-SetupCheckpoint -Name "Phase1"
            Test-SetupCheckpoint -Name "Phase1" | Should -Be $true
        }

        It "returns false when checkpoint does not exist" {
            Set-SetupCheckpoint -Name "Phase1"
            Test-SetupCheckpoint -Name "Phase2" | Should -Be $false
        }

        It "returns false when no checkpoint file exists" {
            Test-SetupCheckpoint -Name "Phase1" | Should -Be $false
        }

        It "returns false when INTERCLAW_RUN_ID is empty" {
            $saved = $env:INTERCLAW_RUN_ID
            $env:INTERCLAW_RUN_ID = ""
            Set-SetupCheckpoint -Name "Phase1"
            Test-SetupCheckpoint -Name "Phase1" | Should -Be $false
            $env:INTERCLAW_RUN_ID = $saved
        }
    }

    Context "Clear-SetupCheckpoints" -Tag "DeployState" {
        AfterEach {
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            if (Test-Path $checkpointFile) { Remove-Item $checkpointFile -Force }
        }

        It "removes all checkpoints for the current run" {
            Set-SetupCheckpoint -Name "Phase1"
            Set-SetupCheckpoint -Name "Phase2"
            Clear-SetupCheckpoints
            Test-SetupCheckpoint -Name "Phase1" | Should -Be $false
            Test-SetupCheckpoint -Name "Phase2" | Should -Be $false
        }

        It "removes checkpoints for a specific run ID" {
            Set-SetupCheckpoint -Name "Phase1"
            Clear-SetupCheckpoints -RunId "test-run-001"
            Test-SetupCheckpoint -Name "Phase1" | Should -Be $false
        }

        It "deletes the checkpoint file when no runs remain" {
            Set-SetupCheckpoint -Name "Phase1"
            Clear-SetupCheckpoints
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            Test-Path $checkpointFile | Should -Be $false
        }

        It "silently returns when INTERCLAW_RUN_ID is empty" {
            $saved = $env:INTERCLAW_RUN_ID
            $env:INTERCLAW_RUN_ID = ""
            { Clear-SetupCheckpoints } | Should -Not -Throw
            $env:INTERCLAW_RUN_ID = $saved
        }
    }

    Context "New-SetupErrorsTasksFile" -Tag "DeployState" {
        It "returns silently when no errors exist" {
            New-SetupErrorsTasksFile | Should -BeNullOrEmpty
        }

        It "creates a reviewer-ready task file" {
            Add-SetupError -Phase "Phase1" -Message "Test error"
            New-SetupErrorsTasksFile

            $logsDir = Join-Path (Join-Path $script:TestRepoRoot "Tasks") "Logs"
            $files = Get-ChildItem -Path $logsDir -Filter "*setup-errors*" -ErrorAction SilentlyContinue
            $files.Count | Should -BeGreaterThan 0
        }

        It "includes deferred human tasks for recoverable errors" {
            Add-SetupError -Phase "Phase1" -Message "Recoverable item" -Recoverable $true
            New-SetupErrorsTasksFile

            $logsDir = Join-Path (Join-Path $script:TestRepoRoot "Tasks") "Logs"
            $files = Get-ChildItem -Path $logsDir -Filter "*setup-errors*" -ErrorAction SilentlyContinue
            $latest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $content = Get-Content $latest.FullName -Raw
            $content | Should -Match "Deferred Human Tasks"
        }
    }

    Context "Invoke-DeployStatePhase" -Tag "DeployState" {
        AfterEach {
            $checkpointFile = Join-Path (Join-Path $script:TestHomeDir ".ORCHESTRATOR") "checkpoints.json"
            if (Test-Path $checkpointFile) { Remove-Item $checkpointFile -Force }
        }

        It "executes the script block and records success" {
            $state = @{ executed = $false }
            Invoke-DeployStatePhase -Phase "Phase1" -ScriptBlock { $state.executed = $true }
            $state.executed | Should -Be $true
            (Get-Module -Name SalmonRun.DeployState).SessionState.PSVariable.GetValue('SetupPhasesCompleted').Contains("Phase1") | Should -Be $true
        }

        It "sets a checkpoint on successful execution" {
            Invoke-DeployStatePhase -Phase "Phase1" -ScriptBlock { }
            Test-SetupCheckpoint -Name "Phase1" | Should -Be $true
        }

        It "skips execution if checkpoint already exists" {
            Set-SetupCheckpoint -Name "Phase1"
            $state = @{ executed = $false }
            Invoke-DeployStatePhase -Phase "Phase1" -ScriptBlock { $state.executed = $true }
            $state.executed | Should -Be $false
        }

        It "records error and re-throws when non-recoverable" {
            $result = InModuleScope -ModuleName 'SalmonRun.DeployState' -ScriptBlock {
                Clear-DeployState
                Clear-SetupCheckpoints
                $threw = $false
                try {
                    Invoke-DeployStatePhase -Phase "FailPhase" -ScriptBlock { throw "Fatal failure" }
                } catch {
                    $threw = $true
                }
                return @{ Threw = $threw; Error = $script:InterclawErrors[0] }
            }
            $result.Threw | Should -Be $true
            $result.Error | Should -Not -BeNullOrEmpty
            $result.Error.Recoverable | Should -Be $false
        }

        It "records error without re-throwing when recoverable" {
            $result = InModuleScope -ModuleName 'SalmonRun.DeployState' -ScriptBlock {
                Clear-DeployState
                Clear-SetupCheckpoints
                $threw = $false
                try {
                    Invoke-DeployStatePhase -Phase "RecPhase" -ScriptBlock { throw "Recoverable failure" } -Recoverable
                } catch {
                    $threw = $true
                }
                return @{ Threw = $threw; Error = $script:InterclawErrors[0] }
            }
            $result.Threw | Should -Be $false
            $result.Error | Should -Not -BeNullOrEmpty
            $result.Error.Recoverable | Should -Be $true
        }

        It "does not set checkpoint on failure" {
            { Invoke-DeployStatePhase -Phase "FailPhase" -ScriptBlock { throw "Fail" } } | Should -Throw
            Test-SetupCheckpoint -Name "FailPhase" | Should -Be $false
        }

        It "has Invoke-SetupPhase as an alias" {
            $alias = Get-Alias -Name Invoke-SetupPhase -ErrorAction SilentlyContinue
            $alias | Should -Not -BeNullOrEmpty
            $alias.Definition | Should -Be "Invoke-DeployStatePhase"
        }
    }
}
