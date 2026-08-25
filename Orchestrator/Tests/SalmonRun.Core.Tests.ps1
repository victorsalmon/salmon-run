#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
param()

Describe "SalmonRun.Core Module FunctionsToExport" -Tag "Core", "Regression-Only" {
    It "no longer exports Get-InterclawGitLock or Remove-InterclawGitLock" {
        $manifestPath = Join-Path $PSScriptRoot "..\Modules\SalmonRun.Core\SalmonRun.Core.psd1"
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $exports = $manifest.FunctionsToExport
        $exports | Should -Not -Contain "Get-InterclawGitLock"
        $exports | Should -Not -Contain "Remove-InterclawGitLock"
    }
}

Describe "SalmonRun.Core Module" -Tag "Core" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }

        $pathsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        if (Test-Path $pathsPath) { . $pathsPath }

        $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath

        $configPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Config\SalmonRun.Config.ps1'
        if (Test-Path $configPath) { . $configPath }

        $processPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.Process\Interclaw.Process.ps1'
        if (Test-Path $processPath) { . $processPath }

        $deployStatePath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.DeployState\SalmonRun.DeployState.ps1'
        if (Test-Path $deployStatePath) { . $deployStatePath }

        $wfPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.WorkflowEvents\Public\Write-WorkflowEvent.ps1'
        if (Test-Path $wfPath) { . $wfPath }

        $gwfPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.WorkflowEvents\Public\Get-WorkflowEvents.ps1'
        if (Test-Path $gwfPath) { . $gwfPath }

        if (-not (Get-Command 'Invoke-WithCredentialSwap' -ErrorAction SilentlyContinue)) {
            function Invoke-WithCredentialSwap {
                param(
                    [Parameter(Mandatory = $true)]
                    [SecureString]$AccessKeyId,
                    [Parameter(Mandatory = $true)]
                    [SecureString]$SecretAccessKey,
                    [Parameter(Mandatory = $true)]
                    [scriptblock]$ScriptBlock,
                    [Parameter(Mandatory = $false)]
                    [string]$Region = "us-east-1"
                )
                $SavedKeyId = $env:AWS_ACCESS_KEY_ID
                $SavedSecretKey = $env:AWS_SECRET_ACCESS_KEY
                $SavedSessionToken = $env:AWS_SESSION_TOKEN
                $SavedProfile = $env:AWS_PROFILE
                $SavedDefaultProfile = $env:AWS_DEFAULT_PROFILE
                $SavedSsoProfile = $env:AWS_SSO_PROFILE
                $SavedConfigFile = $env:AWS_CONFIG_FILE
                $SavedSharedCredentialsFile = $env:AWS_SHARED_CREDENTIALS_FILE

                $plainAccessKey = [System.Net.NetworkCredential]::new("", $AccessKeyId).Password
                $plainSecretKey = [System.Net.NetworkCredential]::new("", $SecretAccessKey).Password

                $TempCredDir = Join-Path $env:TEMP "oc-credswap-$(Get-Random)"
                New-Item -ItemType Directory -Path $TempCredDir -Force | Out-Null
                $TempCredFile = Join-Path $TempCredDir "credentials"
                $TempConfigFile = Join-Path $TempCredDir "config"

                @"
[ORCHESTRATOR-swap]
aws_access_key_id = $plainAccessKey
aws_secret_access_key = $plainSecretKey
"@ | Set-Content -Path $TempCredFile -Encoding UTF8

                @"
[profile ORCHESTRATOR-swap]
region = $Region
"@ | Set-Content -Path $TempConfigFile -Encoding UTF8

                try {
                    $env:AWS_ACCESS_KEY_ID = $plainAccessKey
                    $env:AWS_SECRET_ACCESS_KEY = $plainSecretKey
                    $env:AWS_SHARED_CREDENTIALS_FILE = $TempCredFile
                    $env:AWS_CONFIG_FILE = $TempConfigFile
                    $env:AWS_PROFILE = "ORCHESTRATOR-swap"
                    Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
                    Remove-Item Env:\AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue
                    Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue

                    & $ScriptBlock
                }
                finally {
                    if (-not [string]::IsNullOrWhiteSpace($SavedKeyId)) { $env:AWS_ACCESS_KEY_ID = $SavedKeyId }
                    else { Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedSecretKey)) { $env:AWS_SECRET_ACCESS_KEY = $SavedSecretKey }
                    else { Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedSessionToken)) { $env:AWS_SESSION_TOKEN = $SavedSessionToken }
                    else { Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedProfile)) { $env:AWS_PROFILE = $SavedProfile }
                    else { Remove-Item Env:\AWS_PROFILE -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedDefaultProfile)) { $env:AWS_DEFAULT_PROFILE = $SavedDefaultProfile }
                    else { Remove-Item Env:\AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedSsoProfile)) { $env:AWS_SSO_PROFILE = $SavedSsoProfile }
                    else { Remove-Item Env:\AWS_SSO_PROFILE -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedConfigFile)) { $env:AWS_CONFIG_FILE = $SavedConfigFile }
                    else { Remove-Item Env:\AWS_CONFIG_FILE -ErrorAction SilentlyContinue }
                    if (-not [string]::IsNullOrWhiteSpace($SavedSharedCredentialsFile)) { $env:AWS_SHARED_CREDENTIALS_FILE = $SavedSharedCredentialsFile }
                    else { Remove-Item Env:\AWS_SHARED_CREDENTIALS_FILE -ErrorAction SilentlyContinue }
                    Remove-Item -Path $TempCredDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
    }

Describe "WorkflowEvents" -Tag "Core" {
    BeforeAll {
        $script:TestEventsDir = Join-Path $env:TEMP "Interclaw-WorkflowEvents-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:TestEventsDir -Force
        $diagnosticsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        try { . $helpersPath } catch { Write-Debug "Core module load skipped: $_" }
        $wfPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.WorkflowEvents\Public\Write-WorkflowEvent.ps1'
        if (Test-Path $wfPath) { . $wfPath }
        $gwfPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.WorkflowEvents\Public\Get-WorkflowEvents.ps1'
        if (Test-Path $gwfPath) { . $gwfPath }
        if (-not (Test-Path function:Get-SalmonRunRepoRoot)) {
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:TestEventsDir } -Force
        } else {
            $script:SavedRepoRoot = & (Get-Item function:Get-SalmonRunRepoRoot)
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:TestEventsDir } -Force
        }
        $script:SavedAgentId = $env:OC_RESERVATION_AGENT_ID
        $env:OC_RESERVATION_AGENT_ID = "pester-test-agent-001"
    }
    AfterAll {
        if (Test-Path $script:TestEventsDir) { Remove-Item -Recurse -Force $script:TestEventsDir }
        if ($script:SavedRepoRoot) {
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value $script:SavedRepoRoot -Force -ErrorAction SilentlyContinue
        }
        if ($script:SavedAgentId) { $env:OC_RESERVATION_AGENT_ID = $script:SavedAgentId } else { Remove-Item Env:\OC_RESERVATION_AGENT_ID -ErrorAction SilentlyContinue }
    }
    AfterEach {
        Remove-Item "$script:TestEventsDir/Tasks/Logs" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Write-WorkflowEvent appends JSONL and increments IDs' {
        Write-WorkflowEvent -Type SESSION_START -AgentId "test" -Phase coder
        $logFile = Join-Path $script:TestEventsDir "Tasks/Logs" "workflow-events.log"
        Test-Path $logFile | Should -Be $true
        $lines = Get-Content $logFile
        $lines.Count | Should -Be 1

        Write-WorkflowEvent -Type CLAIM -Files @("file.md") -AgentId "test" -Phase coder
        $lines = Get-Content $logFile
        $lines.Count | Should -Be 2

        $first = $lines[0] | ConvertFrom-Json
        $second = $lines[1] | ConvertFrom-Json
        $second.id | Should -Be ($first.id + 1)
    }

    It 'Get-WorkflowEvents returns only new events per agent' -Skip {
        Write-WorkflowEvent -Type CLAIM -Files @("a.md") -AgentId "test" -Phase coder
        Write-WorkflowEvent -Type RELEASE -Files @("a.md") -AgentId "test" -Phase coder

        $events = Get-WorkflowEvents -AgentId "test"
        $events.Count | Should -Be 2
        $events[0].type | Should -Be "CLAIM"
        $events[1].type | Should -Be "RELEASE"

        $events2 = Get-WorkflowEvents -AgentId "test"
        $events2.Count | Should -Be 0
    }

    It 'Write-WorkflowEvent -Clear deletes log and offsets' {
        Write-WorkflowEvent -Type SESSION_START -AgentId "test" -Phase coder
        $logFile = Join-Path $script:TestEventsDir "Tasks/Logs" "workflow-events.log"
        Test-Path $logFile | Should -Be $true

        Write-WorkflowEvent -Clear -AgentId "auditor" -Phase audit
        Test-Path $logFile | Should -Be $false
    }

    It 'handles missing log gracefully' {
        $events = Get-WorkflowEvents -AgentId "nonexistent"
        $events | Should -BeNullOrEmpty
        { Write-WorkflowEvent -Type CLAIM -Files @("x.md") -AgentId "test" -Phase coder } | Should -Not -Throw
    }

    It 'mutable default $Files is not shared across calls - regression' -Tag "Regression-Only" {
        Write-WorkflowEvent -Type RELEASE -Files @("a.md") -AgentId "test" -Phase coder
        $logFile = Join-Path $script:TestEventsDir "Tasks/Logs" "workflow-events.log"
        $lineA = (Get-Content $logFile -Tail 1) | ConvertFrom-Json
        $lineA.files | Should -Be @("a.md")

        Write-WorkflowEvent -Type RELEASE -AgentId "test" -Phase coder
        $lineB = (Get-Content $logFile -Tail 1) | ConvertFrom-Json
        $lineB.files | Should -Be @()
        $lineB.files.Count | Should -Be 0
    }
}

Describe "Invoke-WithCredentialSwap" -Tag "Core" {
    BeforeAll {
        $script:SavedAwsAccessKeyId = $env:AWS_ACCESS_KEY_ID
        $script:SavedAwsSecretKey = $env:AWS_SECRET_ACCESS_KEY
        $script:SavedAwsSessionToken = $env:AWS_SESSION_TOKEN
        $script:SavedAwsProfile = $env:AWS_PROFILE
    }

    AfterAll {
        if ($script:SavedAwsAccessKeyId) { $env:AWS_ACCESS_KEY_ID = $script:SavedAwsAccessKeyId } else { Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue }
        if ($script:SavedAwsSecretKey) { $env:AWS_SECRET_ACCESS_KEY = $script:SavedAwsSecretKey } else { Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue }
        if ($script:SavedAwsSessionToken) { $env:AWS_SESSION_TOKEN = $script:SavedAwsSessionToken } else { Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
        if ($script:SavedAwsProfile) { $env:AWS_PROFILE = $script:SavedAwsProfile } else { Remove-Item Env:\AWS_PROFILE -ErrorAction SilentlyContinue }
    }

        BeforeEach {
            $env:AWS_ACCESS_KEY_ID = 'original_key'
            $env:AWS_SECRET_ACCESS_KEY = 'original_secret'
            $env:AWS_SESSION_TOKEN = 'original_token'
            $env:AWS_PROFILE = 'original_profile'
        }

        It "executes script block with swapped credentials" {
            $captured = $null
            Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString 'new_key' -AsPlainText -Force) -SecretAccessKey (ConvertTo-SecureString 'new_secret' -AsPlainText -Force) -ScriptBlock {
                $script:captured = $env:AWS_ACCESS_KEY_ID
            }
            $script:captured | Should -Be 'new_key'
        }

        It "restores original credentials after execution" {
            Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString 'new_key' -AsPlainText -Force) -SecretAccessKey (ConvertTo-SecureString 'new_secret' -AsPlainText -Force) -ScriptBlock {}
            $env:AWS_ACCESS_KEY_ID | Should -Be 'original_key'
            $env:AWS_SECRET_ACCESS_KEY | Should -Be 'original_secret'
            $env:AWS_SESSION_TOKEN | Should -Be 'original_token'
            $env:AWS_PROFILE | Should -Be 'original_profile'
        }

        It "restores original credentials even when script block throws" {
            {
                Invoke-WithCredentialSwap -AccessKeyId (ConvertTo-SecureString 'new_key' -AsPlainText -Force) -SecretAccessKey (ConvertTo-SecureString 'new_secret' -AsPlainText -Force) -ScriptBlock {
                    throw "intentional error"
                }
            } | Should -Throw "intentional error"

            $env:AWS_ACCESS_KEY_ID | Should -Be 'original_key'
            $env:AWS_SECRET_ACCESS_KEY | Should -Be 'original_secret'
            $env:AWS_SESSION_TOKEN | Should -Be 'original_token'
            $env:AWS_PROFILE | Should -Be 'original_profile'
        }
    }
}

Describe "Checkpoint system and CredentialSwap" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }
        $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $deployStatePath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.DeployState\SalmonRun.DeployState.ps1'
        if (Test-Path $deployStatePath) { . $deployStatePath }
        $processPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.Process\Interclaw.Process.ps1'
        if (Test-Path $processPath) { . $processPath }
    }
    Context "Checkpoint system" -Tag "Core", "Regression-Only" {
        BeforeAll {
            $script:CheckpointTestDir = Join-Path $env:TEMP "Interclaw-Checkpoint-$(Get-Random)"
            New-Item -ItemType Directory -Path $script:CheckpointTestDir -Force | Out-Null

            # The checkpoint functions resolve their home dir through Get-HomeDir
            # (which caches $env:HOME/$env:INTERCLAW_HOME on first call). Mock it
            # directly so the tests are hermetic instead of mutating env vars that
            # the cache ignores.
            function global:Get-HomeDir { $script:CheckpointTestDir }

            $script:SavedRunId = $env:INTERCLAW_RUN_ID
            $env:INTERCLAW_RUN_ID = "checkpoint-test-run-001"
        }

        AfterAll {
            if (Test-Path $script:CheckpointTestDir) {
                Remove-Item -Recurse -Force $script:CheckpointTestDir
            }
            Remove-Item function:global:Get-HomeDir -ErrorAction SilentlyContinue
            if ($script:SavedRunId) { $env:INTERCLAW_RUN_ID = $script:SavedRunId } else { Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue }
        }

        It "returns false for unset checkpoint" {
            Test-SetupCheckpoint -Name "NeverSet" | Should -Be $false
        }

        It "returns true after setting a checkpoint" {
            Set-SetupCheckpoint -Name "PhaseTest"
            Test-SetupCheckpoint -Name "PhaseTest" | Should -Be $true
        }

        It "persists checkpoint to disk" {
            $checkpointFile = Join-Path $script:CheckpointTestDir ".ORCHESTRATOR" "checkpoints.json"
            Test-Path $checkpointFile | Should -Be $true
            $content = Get-Content $checkpointFile -Raw | ConvertFrom-Json
            $content."checkpoint-test-run-001".PhaseTest.Status | Should -Be "complete"
        }

        It "isolates checkpoints by run ID" {
            $env:INTERCLAW_RUN_ID = "checkpoint-test-run-002"
            Test-SetupCheckpoint -Name "PhaseTest" | Should -Be $false
            Set-SetupCheckpoint -Name "PhaseTest"
            Test-SetupCheckpoint -Name "PhaseTest" | Should -Be $true
            $env:INTERCLAW_RUN_ID = "checkpoint-test-run-001"
            Test-SetupCheckpoint -Name "PhaseTest" | Should -Be $true
        }

        It "silently skips when INTERCLAW_RUN_ID is not set" {
            Remove-Item Env:\INTERCLAW_RUN_ID -ErrorAction SilentlyContinue
            { Set-SetupCheckpoint -Name "NoRunId" } | Should -Not -Throw
            Test-SetupCheckpoint -Name "NoRunId" | Should -Be $false
            $env:INTERCLAW_RUN_ID = "checkpoint-test-run-001"
        }

        It "handles multiple checkpoints under same run ID" {
            Set-SetupCheckpoint -Name "PhaseA"
            Set-SetupCheckpoint -Name "PhaseB"
            Set-SetupCheckpoint -Name "PhaseC"
            Test-SetupCheckpoint -Name "PhaseA" | Should -Be $true
            Test-SetupCheckpoint -Name "PhaseB" | Should -Be $true
            Test-SetupCheckpoint -Name "PhaseC" | Should -Be $true
            Test-SetupCheckpoint -Name "PhaseD" | Should -Be $false
        }

        It "disposes mutex after Set-SetupCheckpoint (regression)" {
            Set-SetupCheckpoint -Name "MutexDispose"
            $checkpointFile = Join-Path $script:CheckpointTestDir ".ORCHESTRATOR" "checkpoints.json"
            Test-Path $checkpointFile | Should -Be $true
            $content = Get-Content $checkpointFile -Raw | ConvertFrom-Json
            $content."checkpoint-test-run-001".MutexDispose.Status | Should -Be "complete"
        }
    }

    Context "Invoke-NativeCommand" -Tag "Core" {
        It "captures exit code 0 for successful command" {
            $result = Invoke-NativeCommand { cmd /c "echo hello" }
            $result.Success | Should -Be $true
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Be "hello"
        }

        It "captures non-zero exit code even when output is assigned" {
            $result = Invoke-NativeCommand { cmd /c "exit 42" }
            $result.Success | Should -Be $false
            $result.ExitCode | Should -Be 42
        }

        It "preserves global LASTEXITCODE after execution" {
            Invoke-NativeCommand { cmd /c "exit 1" } | Out-Null
            $global:LASTEXITCODE | Should -Be 1
        }

        It "captures stderr merged into output" {
            $result = Invoke-NativeCommand { cmd /c "echo stdout" 2>&1; cmd /c "echo stderr" 2>&1 }
            $result.Output | Should -Match "stdout"
            $result.Output | Should -Match "stderr"
        }

        It "returns .Output as [string] not [object[]] → regression guard for Object[]→string crash" {
            $result = Invoke-NativeCommand { cmd /c "echo line1" 2>&1; cmd /c "echo line2" 2>&1; cmd /c "echo line3" 2>&1 }
            $result.Output | Should -BeOfType [string]
            $result.Output | Should -Match "line1"
            $result.Output | Should -Match "line2"
            $result.Output | Should -Match "line3"
        }
    }
}

Describe "Invoke-AgentPollingLoop" -Tag "Core" {
    BeforeAll {
        $script:PollTestDir = Join-Path $env:TEMP "Interclaw-Poll-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:PollTestDir -Force

        if (-not (Test-Path function:Get-SalmonRunRepoRoot)) {
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:PollTestDir } -Force
        }
    }
    AfterAll {
        if (Test-Path $script:PollTestDir) { Remove-Item -Recurse -Force $script:PollTestDir }
    }

    It "returns false when no files appear within max cycles" -Skip {
        $result = Invoke-AgentPollingLoop -TaskDirectory "Tasks/Code" -RoleName "pester" -PollIntervalSeconds 1 -MaxIdleCycles 1
        $result | Should -Be $false
    }

    It "returns true when files appear during polling" -Skip {
        $watchDir = Join-Path $script:PollTestDir "Tasks/Code"
        $null = New-Item -ItemType Directory -Path $watchDir -Force

        $job = Start-Job -ScriptBlock {
            param($dir, $poll, $max)
            Start-Sleep -Milliseconds 300
            "test" | Set-Content -Path (Join-Path $dir "test-plan.md") -Encoding utf8
            Invoke-AgentPollingLoop -TaskDirectory "Tasks/Code" -RoleName "pester" -PollIntervalSeconds 1 -MaxIdleCycles $max
        } -ArgumentList $watchDir, 1, 3

        $result = $job | Wait-Job -Timeout 10 | Receive-Job
        $result | Should -Be $true
    }
}

Describe "Agent PID / Heartbeat Helpers" -Tag "Core" {
    BeforeAll {
        $diagnosticsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
        if (Test-Path $diagnosticsPath) { . $diagnosticsPath }

        $pathsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Paths\SalmonRun.Paths.ps1'
        if (Test-Path $pathsPath) { . $pathsPath }

        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        if (Test-Path $corePublic) {
            . (Join-Path $corePublic 'Write-AtomicFile.ps1')
        }

        $agentLifecyclePublic = Join-Path $PSScriptRoot '..\Modules\Interclaw.AgentLifecycle\Public'
        if (Test-Path $agentLifecyclePublic) {
            Get-ChildItem -Path $agentLifecyclePublic -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }

        $script:TestAgentId = "pester-test-agent-999-99"
        $script:AgentsDir = Join-Path (Get-InterclawRepoRoot) "Tasks\Logs\agents"
    }
    AfterEach {
        Remove-Item "$script:AgentsDir\$script:TestAgentId*" -Force -ErrorAction SilentlyContinue
    }
    AfterAll {
        Remove-Item "$script:AgentsDir\$script:TestAgentId*" -Force -ErrorAction SilentlyContinue
    }

    Context "Write-AgentPidFile" -Tag "Core" {
        It "creates a PID file with the current shell PID" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            $pidPath = "$script:AgentsDir/$script:TestAgentId.pid"
            Test-Path $pidPath | Should -Be $true
            (Get-Content $pidPath -Raw).Trim() | Should -Be $PID.ToString()
        }

        It "creates the agents directory if absent" {
            Remove-Item $script:AgentsDir -Force -Recurse -ErrorAction SilentlyContinue
            Write-AgentPidFile -AgentId $script:TestAgentId
            $pidPath = "$script:AgentsDir/$script:TestAgentId.pid"
            Test-Path $pidPath | Should -Be $true
        }

        It "registers an EngineEvent for cleanup" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            $subscriber = Get-EventSubscriber -SourceIdentifier "Interclaw.PidCleanup_$script:TestAgentId" -Force -ErrorAction SilentlyContinue
            $subscriber | Should -Not -BeNullOrEmpty
        }

        It "returns the path to the PID file" {
            $result = Write-AgentPidFile -AgentId $script:TestAgentId
            $result | Should -Match "$script:TestAgentId\.pid$"
        }
    }

    Context "Write-AgentHeartbeat" -Tag "Core" {
        It "creates a heartbeat file with a valid timestamp" {
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $hbPath = "$script:AgentsDir/$script:TestAgentId.heartbeat"
            Test-Path $hbPath | Should -Be $true
            $content = (Get-Content $hbPath -Raw).Trim()
            { [datetime]::Parse($content) } | Should -Not -Throw
        }

        It "updates the heartbeat file on subsequent calls" {
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $ts1 = (Get-Content "$script:AgentsDir/$script:TestAgentId.heartbeat" -Raw).Trim()
            Start-Sleep -Milliseconds 10
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $ts2 = (Get-Content "$script:AgentsDir/$script:TestAgentId.heartbeat" -Raw).Trim()
            $ts2 | Should -Not -Be $ts1
        }

        It "does not throw when agents dir is missing" {
            Remove-Item $script:AgentsDir -Force -Recurse -ErrorAction SilentlyContinue
            { Write-AgentHeartbeat -AgentId $script:TestAgentId } | Should -Not -Throw
        }
    }

    Context "Test-AgentAlive" -Tag "Core" {
        It "returns correct properties when agent is alive with PID and heartbeat" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $result = Test-AgentAlive -AgentId $script:TestAgentId
            $result.AgentId | Should -Be $script:TestAgentId
            $result.HasPidFile | Should -Be $true
            $result.HasHeartbeat | Should -Be $true
            $result.ProcessAlive | Should -Be $true
            $result.Pid | Should -Be $PID
            $result.Stale | Should -Be $false
        }

        It "detects stale when PID file points to a dead process" {
            "999999" | Out-File "$script:AgentsDir/$script:TestAgentId.pid" -Encoding utf8 -NoNewline
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $result = Test-AgentAlive -AgentId $script:TestAgentId
            $result.ProcessAlive | Should -Be $false
            $result.Stale | Should -Be $true
        }

        It "returns not stale when no files exist (backward compat)" {
            $result = Test-AgentAlive -AgentId "nonexistent-agent-000-00"
            $result.HasPidFile | Should -Be $false
            $result.HasHeartbeat | Should -Be $false
            $result.Stale | Should -Be $false
        }

        It "keeps process alive as ground truth even with stale heartbeat" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            "2000-01-01T00:00:00Z" | Out-File "$script:AgentsDir/$script:TestAgentId.heartbeat" -Encoding utf8 -NoNewline
            $result = Test-AgentAlive -AgentId $script:TestAgentId -HeartbeatStaleThresholdSeconds 60
            $result.ProcessAlive | Should -Be $true
            $result.HeartbeatStale | Should -Be $true
            $result.Stale | Should -Be $false
        }

        It "returns not stale with fresh heartbeat" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            $result = Test-AgentAlive -AgentId $script:TestAgentId -HeartbeatStaleThresholdSeconds 60
            $result.HeartbeatStale | Should -Be $false
            $result.Stale | Should -Be $false
        }
    }

    Context "Clear-StaleAgentFiles" -Tag "Core" {
        It "removes PID and heartbeat files for dead agents" {
            "999999" | Out-File "$script:AgentsDir/${testAgentId}dead.pid" -Encoding utf8 -NoNewline
            "2000-01-01T00:00:00Z" | Out-File "$script:AgentsDir/${testAgentId}dead.heartbeat" -Encoding utf8 -NoNewline
            Clear-StaleAgentFiles
            Test-Path "$script:AgentsDir/${testAgentId}dead.pid" | Should -Be $false
            Test-Path "$script:AgentsDir/${testAgentId}dead.heartbeat" | Should -Be $false
        }

        It "does not remove files for alive agents" {
            Write-AgentPidFile -AgentId $script:TestAgentId
            Write-AgentHeartbeat -AgentId $script:TestAgentId
            Clear-StaleAgentFiles
            Test-Path "$script:AgentsDir/$script:TestAgentId.pid" | Should -Be $true
            Test-Path "$script:AgentsDir/$script:TestAgentId.heartbeat" | Should -Be $true
        }

        It "removes log files only with -RemoveLogs" {
            "999999" | Out-File "$script:AgentsDir/${testAgentId}logtest.pid" -Encoding utf8 -NoNewline
            "test log entry" | Out-File "$script:AgentsDir/${testAgentId}logtest.log" -Encoding utf8
            Clear-StaleAgentFiles
            Test-Path "$script:AgentsDir/${testAgentId}logtest.log" | Should -Be $true
            Clear-StaleAgentFiles -RemoveLogs
            Test-Path "$script:AgentsDir/${testAgentId}logtest.log" | Should -Be $false
        }

        It "returns count of removed files" {
            "999999" | Out-File "$script:AgentsDir/${testAgentId}a.pid" -Encoding utf8 -NoNewline
            "999999" | Out-File "$script:AgentsDir/${testAgentId}b.pid" -Encoding utf8 -NoNewline
            $count = Clear-StaleAgentFiles
            $count.RemovedCount | Should -BeGreaterOrEqual 2
        }
    }

    Context "Mutex Timeout" -Tag "Core", "Regression-Only" {
        BeforeAll {
            $script:SavedRunId = $env:INTERCLAW_RUN_ID
            $env:INTERCLAW_RUN_ID = "pester-test-run-$(Get-Random)"

            $diagnosticsPath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.Diagnostics\SalmonRun.Diagnostics.ps1'
            if (Test-Path $diagnosticsPath) { . $diagnosticsPath }

            $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
            . $helpersPath

            $deployStatePath = Join-Path $PSScriptRoot '..\..\Skills\Docker\Modules\SalmonRun.DeployState\SalmonRun.DeployState.ps1'
            if (Test-Path $deployStatePath) { . $deployStatePath }

            $wfPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.WorkflowEvents\Public\Write-WorkflowEvent.ps1'
            if (Test-Path $wfPath) { . $wfPath }
            $gwfPath = Join-Path $PSScriptRoot '..\Modules\Interclaw.WorkflowEvents\Public\Get-WorkflowEvents.ps1'
            if (Test-Path $gwfPath) { . $gwfPath }
        }
        AfterAll {
            $env:INTERCLAW_RUN_ID = $script:SavedRunId
        }
        It "Set-SetupCheckpoint throws on mutex timeout" {
            $mtx = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-Checkpoint-Mutex")
            $mtx.WaitOne(100) | Out-Null
            try {
                { Set-SetupCheckpoint -Name "test" -ErrorAction Stop } | Should -Throw
            } finally {
                $null = $mtx.Release()
                $mtx.Dispose()
            }
        }

        It "Clear-SetupCheckpoints throws on mutex timeout" {
            Set-SetupCheckpoint -Name "PreconditionForClear"
            $mtx = New-Object System.Threading.Semaphore(1, 1, "Global\Interclaw-Checkpoint-Mutex")
            $mtx.WaitOne(100) | Out-Null
            try {
                { Clear-SetupCheckpoints -RunId "test" -ErrorAction Stop } | Should -Throw
            } finally {
                $null = $mtx.Release()
                $mtx.Dispose()
            }
        }

        It "Write-WorkflowEvent throws on mutex timeout" {
            $job = Start-Job -ScriptBlock {
                param($semaName)
                $mtx = New-Object System.Threading.Semaphore(1, 1, $semaName)
                $mtx.WaitOne(-1) | Out-Null
                Start-Sleep -Seconds 15
                $mtx.Release()
                $mtx.Dispose()
            } -ArgumentList "Global\Interclaw-WorkflowEvents-Mutex"
            Start-Sleep -Milliseconds 500
            try {
                { Write-WorkflowEvent -Type TEST -AgentId "test" -Phase test -ErrorAction Stop } | Should -Throw
            } finally {
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -ErrorAction SilentlyContinue
            }
        }

        It "Get-WorkflowEvents warns but does not throw on mutex timeout" {
            $job = Start-Job -ScriptBlock {
                param($semaName)
                $mtx = New-Object System.Threading.Semaphore(1, 1, $semaName)
                $mtx.WaitOne(-1) | Out-Null
                Start-Sleep -Seconds 15
                $mtx.Release()
                $mtx.Dispose()
            } -ArgumentList "Global\Interclaw-WorkflowEvents-Mutex"
            Start-Sleep -Milliseconds 500
            try {
                $result = Get-WorkflowEvents -AgentId "test" -ErrorAction SilentlyContinue
                $result | Should -BeNullOrEmpty
            } finally {
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -ErrorAction SilentlyContinue
        }
    }
}
}

Describe "Lock-File / Unlock-File" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $script:LockTestDir = Join-Path $env:TEMP "Interclaw-FileLock-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:LockTestDir -Force

        $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath

        $publicDir = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        Get-ChildItem -Path $publicDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }

        # Load Interclaw.Locking for Lock-File/Unlock-File (moved from Core)
        $lockingDir = Join-Path $PSScriptRoot '..\Modules\Interclaw.Locking\Public'
        if (Test-Path $lockingDir) {
            Get-ChildItem -Path $lockingDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }

        if (-not (Test-Path function:Get-SalmonRunRepoRoot)) {
            $script:GetInterclawRepoRootOrig = $null
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:LockTestDir } -Force
        } else {
            $script:GetInterclawRepoRootOrig = Get-Content -Path function:Get-SalmonRunRepoRoot
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:LockTestDir } -Force
        }
    }
    AfterAll {
        if (Test-Path $script:LockTestDir) { Remove-Item -Recurse -Force $script:LockTestDir }
        if ($script:GetInterclawRepoRootOrig) {
            $null = Set-Content -Path function:Get-SalmonRunRepoRoot -Value $script:GetInterclawRepoRootOrig -Force
        }
    }
    AfterEach {
        Remove-Item "$script:LockTestDir/Tasks/Locks" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "Lock-File creates .lock files" {
        Lock-File -FileNames @("test-plan") | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/test-plan.lock" | Should -Be $true
    }

    It "Lock-File returns false when lock already held" {
        Lock-File -FileNames @("contested") | Should -Be $true
        Lock-File -FileNames @("contested") -MaxWaitMs 500 | Should -Be $false
    }

    It "Lock-File acquires multiple locks" {
        Lock-File -FileNames @("a", "b", "c") | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/a.lock" | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/b.lock" | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/c.lock" | Should -Be $true
    }

    It "Lock-File releases acquired locks on failure" {
        $null = New-Item -ItemType Directory -Path "$script:LockTestDir/Tasks/Locks" -Force
        $null = New-Item -ItemType File -Path "$script:LockTestDir/Tasks/Locks/blocker.lock" -Force
        Lock-File -FileNames @("first", "blocker", "second") -MaxWaitMs 200 | Should -Be $false
        Test-Path "$script:LockTestDir/Tasks/Locks/first.lock" | Should -Be $false
        Test-Path "$script:LockTestDir/Tasks/Locks/second.lock" | Should -Be $false
    }

    It "Unlock-File removes .lock files" {
        Lock-File -FileNames @("to-release") | Should -Be $true
        Test-Path "$script:LockTestDir/Tasks/Locks/to-release.lock" | Should -Be $true
        Unlock-File -FileNames @("to-release")
        Test-Path "$script:LockTestDir/Tasks/Locks/to-release.lock" | Should -Be $false
    }

    It "Unlock-File does not throw on missing lock" {
        { Unlock-File -FileNames @("nonexistent") } | Should -Not -Throw
    }

    It "Lock-File writes PID content into lock file" {
        Lock-File -FileNames @("pid-test") | Should -Be $true
        $content = Get-Content -Path "$script:LockTestDir/Tasks/Locks/pid-test.lock" -Raw
        $content.Trim() | Should -Match "^\S+\|\d+\|\S+$"
    }

    It "Lock-File reclaims stale lock from dead PID" {
        $null = New-Item -ItemType Directory -Path "$script:LockTestDir/Tasks/Locks" -Force
        Set-Content -Path "$script:LockTestDir/Tasks/Locks/stale.lock" -Value "dead-agent|99999999|2000-01-01T00:00:00.0000000Z" -NoNewline
        Lock-File -FileNames @("stale") -MaxWaitMs 1000 | Should -Be $true
        $content = Get-Content -Path "$script:LockTestDir/Tasks/Locks/stale.lock" -Raw
        $content.Trim() | Should -Match "^\S+\|\d+\|\S+$"
        $parts = $content.Trim() -split '\|'
        $parts[1] -as [int] | Should -Be $PID
    }

    It "Lock-File cannot reclaim lock held by live PID" {
        $null = New-Item -ItemType Directory -Path "$script:LockTestDir/Tasks/Locks" -Force
        Set-Content -Path "$script:LockTestDir/Tasks/Locks/live.lock" -Value "live-agent|$PID|$(Get-Date -Format 'o')" -NoNewline
        Lock-File -FileNames @("live") -MaxWaitMs 500 | Should -Be $false
    }

    It "Lock-File waits and retries up to MaxWaitMs" {
        $null = New-Item -ItemType Directory -Path "$script:LockTestDir/Tasks/Locks" -Force
        $null = New-Item -ItemType File -Path "$script:LockTestDir/Tasks/Locks/held.lock" -Force
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Lock-File -FileNames @("held") -MaxWaitMs 1000 | Should -Be $false
        $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 900
        $sw.ElapsedMilliseconds | Should -BeLessThan 2000
    }
}

Describe "Register-Namespace / Remove-NamespaceReservation" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $script:NsTestDir = Join-Path $env:TEMP "Interclaw-NsReserve-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:NsTestDir -Force

        $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath

        $publicDir = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        Get-ChildItem -Path $publicDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }

        # Stub Get-InterclawConstants (from SalmonRun.Constants) — Register-Namespace calls it
        if (-not (Get-Command Get-InterclawConstants -ErrorAction SilentlyContinue)) {
            function global:Get-InterclawConstants { @{ NamespaceReclaimThresholdSeconds = 120 } }
        }

        # Load Interclaw.Locking for Register-Namespace/Remove-NamespaceReservation (moved from Core)
        $lockingDir = Join-Path $PSScriptRoot '..\Modules\Interclaw.Locking\Public'
        if (Test-Path $lockingDir) {
            Get-ChildItem -Path $lockingDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }
        $lockingPrivateDir = Join-Path $PSScriptRoot '..\Modules\Interclaw.Locking\Private'
        if (Test-Path $lockingPrivateDir) {
            Get-ChildItem -Path $lockingPrivateDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }

        if (-not (Test-Path function:Get-SalmonRunRepoRoot)) {
            $script:NsGetInterclawRepoRootOrig = $null
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:NsTestDir } -Force
        } else {
            $script:NsGetInterclawRepoRootOrig = Get-Content -Path function:Get-SalmonRunRepoRoot
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value { param() $script:NsTestDir } -Force
        }
    }
    AfterAll {
        if (Test-Path $script:NsTestDir) { Remove-Item -Recurse -Force $script:NsTestDir }
        if ($script:NsGetInterclawRepoRootOrig) {
            Set-Content -Path function:Get-SalmonRunRepoRoot -Value $script:NsGetInterclawRepoRootOrig -Force
        }
    }
    AfterEach {
        Remove-Item "$script:NsTestDir/Tasks/Locks" -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "acquires reservation for a namespace" {
        Register-Namespace -NamespacePrefix "2026.06.03-test-" -AgentId "coder-test-001" | Should -Be $true
        Test-Path "$script:NsTestDir/Tasks/Locks/namespace-2026.06.03-test-.reserved" | Should -Be $true
    }

    It "returns false when namespace already reserved by another live agent" {
        Register-Namespace -NamespacePrefix "busy-ns-" -AgentId "coder-test-001" | Should -Be $true

        $agentsDir = Join-Path $script:NsTestDir "Tasks" "Logs" "agents"
        $null = New-Item -ItemType Directory -Path $agentsDir -Force
        $PID.ToString() | Set-Content -Path "$agentsDir/coder-test-001.pid" -Encoding Ascii -NoNewline
        [datetime]::UtcNow.ToString('o') | Set-Content -Path "$agentsDir/coder-test-001.heartbeat" -Encoding Ascii -NoNewline

        Register-Namespace -NamespacePrefix "busy-ns-" -AgentId "coder-test-002" | Should -Be $false
    }

    It "re-acquires reservation when original holder's heartbeat is stale" {
        Register-Namespace -NamespacePrefix "stale-ns-" -AgentId "coder-stale-001" | Should -Be $true

        $agentsDir = Join-Path $script:NsTestDir "Tasks" "Logs" "agents"
        $null = New-Item -ItemType Directory -Path $agentsDir -Force
        "999999" | Set-Content -Path "$agentsDir/coder-stale-001.pid" -Encoding Ascii -NoNewline
        "2000-01-01T00:00:00Z" | Set-Content -Path "$agentsDir/coder-stale-001.heartbeat" -Encoding Ascii -NoNewline

        Register-Namespace -NamespacePrefix "stale-ns-" -AgentId "coder-test-002" | Should -Be $true
    }

    It "same agent re-acquires its own reservation" {
        Register-Namespace -NamespacePrefix "self-ns-" -AgentId "coder-test-001" | Should -Be $true
        Register-Namespace -NamespacePrefix "self-ns-" -AgentId "coder-test-001" | Should -Be $true
    }

    It "Remove-NamespaceReservation removes the reservation file" {
        Register-Namespace -NamespacePrefix "release-ns-" -AgentId "coder-test-001" | Should -Be $true
        Remove-NamespaceReservation -NamespacePrefix "release-ns-"
        Test-Path "$script:NsTestDir/Tasks/Locks/namespace-release-ns-.reserved" | Should -Be $false
    }

    It "Remove-NamespaceReservation does not throw on missing reservation" {
        { Remove-NamespaceReservation -NamespacePrefix "nonexistent-" } | Should -Not -Throw
    }

    It "Lock-File and namespace reservation coexist" {
        Register-Namespace -NamespacePrefix "coexist-ns-" -AgentId "coder-test-001" | Should -Be $true
        Lock-File -FileNames @("coexist-plan") | Should -Be $true
        Test-Path "$script:NsTestDir/Tasks/Locks/namespace-coexist-ns-.reserved" | Should -Be $true
        Test-Path "$script:NsTestDir/Tasks/Locks/coexist-plan.lock" | Should -Be $true
    }
}

Describe "AliasesToExport" -Tag "Core", "Regression-Only" {
    BeforeAll {
        $helpersPath = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $helpersPath
        $publicDir = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        Get-ChildItem -Path $publicDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        # Locking module provides the aliases now
        $lockingDir = Join-Path $PSScriptRoot '..\Modules\Interclaw.Locking\Public'
        if (Test-Path $lockingDir) {
            Get-ChildItem -Path $lockingDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }
        $lockingPrivateDir = Join-Path $PSScriptRoot '..\Modules\Interclaw.Locking\Private'
        if (Test-Path $lockingPrivateDir) {
            Get-ChildItem -Path $lockingPrivateDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
        }
    }

    It "Acquire-FileLock alias resolves to Lock-File" {
        $alias = Get-Alias -Name 'Acquire-FileLock' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.Definition | Should -Be 'Lock-File'
    }

    It "Release-FileLock alias resolves to Unlock-File" {
        $alias = Get-Alias -Name 'Release-FileLock' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.Definition | Should -Be 'Unlock-File'
    }

    It "Acquire-NamespaceReservation alias resolves to Register-Namespace" {
        $alias = Get-Alias -Name 'Acquire-NamespaceReservation' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.Definition | Should -Be 'Register-Namespace'
    }

    It "Reserve-Namespace alias resolves to Register-Namespace" {
        $alias = Get-Alias -Name 'Reserve-Namespace' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.Definition | Should -Be 'Register-Namespace'
    }

    It "Release-NamespaceReservation alias resolves to Remove-NamespaceReservation" {
        $alias = Get-Alias -Name 'Release-NamespaceReservation' -ErrorAction SilentlyContinue
        $alias | Should -Not -BeNullOrEmpty
        $alias.Definition | Should -Be 'Remove-NamespaceReservation'
    }
}

Describe "Get-BackoffDelay" -Tag "Core" {
    BeforeAll {
        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        . (Join-Path $corePublic 'Get-BackoffDelay.ps1')
    }

    It "returns a positive integer for any valid attempt" {
        $result = Get-BackoffDelay -Attempt 1 -Schedule @(30, 120, 300)
        $result | Should -BeGreaterThan 0
    }

    It "uses the first schedule value for attempt 1" {
        $result = Get-BackoffDelay -Attempt 1 -Schedule @(30, 120, 300) -JitterFraction 0
        $result | Should -Be 30
    }

    It "uses the second schedule value for attempt 2" {
        $result = Get-BackoffDelay -Attempt 2 -Schedule @(30, 120, 300) -JitterFraction 0
        $result | Should -Be 120
    }

    It "doubles the last schedule value for attempts beyond schedule length" {
        $result = Get-BackoffDelay -Attempt 5 -Schedule @(30, 120, 300) -JitterFraction 0
        $result | Should -Be 600
    }

    It "caps delay at MaxDelay" {
        $result = Get-BackoffDelay -Attempt 99 -Schedule @(60) -JitterFraction 0 -MaxDelay 100
        $result | Should -Be 100
    }

    It "uses random fallback when schedule is empty" {
        $result = Get-BackoffDelay -Attempt 1 -Schedule @()
        $result | Should -BeGreaterThan 0
        $result | Should -BeLessOrEqual 60
    }

    It "applies jitter within the expected range" {
        $results = 1..20 | ForEach-Object { Get-BackoffDelay -Attempt 1 -Schedule @(100) -JitterFraction 0.25 }
        $min = ($results | Measure-Object -Minimum).Minimum
        $max = ($results | Measure-Object -Maximum).Maximum
        $max | Should -BeGreaterThan $min
    }

    It "Returns the base delay without throwing when -JitterFraction 0" -Tag "Regression" {
        $base = 20
        $result = Get-BackoffDelay -Attempt 3 -Schedule @(5, 10, $base) -JitterFraction 0
        $result | Should -Be $base -Because "zero jitter must return the unjittered base delay, not throw Min >= Max"
    }

    It "Jitters within the expected band for the default fraction" -Tag "Regression" {
        $base = 20
        1..20 | ForEach-Object {
            $r = Get-BackoffDelay -Attempt 3 -Schedule @(5, 10, $base) -JitterFraction 0.25
            $r | Should -BeGreaterOrEqual ($base * 0.75) -Because "jitter floor"
            $r | Should -BeLessOrEqual ($base * 1.25) -Because "jitter ceiling"
        }
    }
}

Describe "Write-AtomicFile" -Tag "Core" {
    BeforeAll {
        $script:AtomicTestDir = Join-Path $env:TEMP "Interclaw-AtomicFile-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:AtomicTestDir -Force
        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        . (Join-Path $corePublic 'Write-AtomicFile.ps1')
    }
    AfterAll {
        if (Test-Path $script:AtomicTestDir) { Remove-Item -Recurse -Force $script:AtomicTestDir }
    }

    It "writes content to the target file" {
        $target = Join-Path $script:AtomicTestDir "test.txt"
        Write-AtomicFile -Path $target -Value "hello world"
        Test-Path $target | Should -Be $true
        (Get-Content $target -Raw).Trim() | Should -Be "hello world"
    }

    It "does not leave .tmp file behind" {
        $target = Join-Path $script:AtomicTestDir "clean.txt"
        Write-AtomicFile -Path $target -Value "clean test"
        Test-Path "$target.tmp" | Should -Be $false
    }

    It "overwrites existing file atomically" {
        $target = Join-Path $script:AtomicTestDir "overwrite.txt"
        Write-AtomicFile -Path $target -Value "first"
        Write-AtomicFile -Path $target -Value "second"
        (Get-Content $target -Raw).Trim() | Should -Be "second"
    }

    It "accepts pipeline input" {
        $target = Join-Path $script:AtomicTestDir "pipeline.txt"
        "pipeline value" | Write-AtomicFile -Path $target
        (Get-Content $target -Raw).Trim() | Should -Be "pipeline value"
    }
}

Describe "Write-AtomicJson" -Tag "Core" {
    BeforeAll {
        $script:JsonTestDir = Join-Path $env:TEMP "Interclaw-AtomicJson-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:JsonTestDir -Force
        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        . (Join-Path $corePublic 'Write-AtomicJson.ps1')
    }
    AfterAll {
        if (Test-Path $script:JsonTestDir) { Remove-Item -Recurse -Force $script:JsonTestDir }
    }

    It "writes valid JSON to the target file" {
        $target = Join-Path $script:JsonTestDir "test.json"
        Write-AtomicJson -Path $target -InputObject @{ key = "value" }
        Test-Path $target | Should -Be $true
        $parsed = Get-Content $target -Raw | ConvertFrom-Json
        $parsed.key | Should -Be "value"
    }

    It "does not leave .tmp file behind" {
        $target = Join-Path $script:JsonTestDir "clean.json"
        Write-AtomicJson -Path $target -InputObject @{ a = 1 }
        Test-Path "$target.tmp" | Should -Be $false
    }

    It "accepts pipeline input" {
        $target = Join-Path $script:JsonTestDir "pipeline.json"
        @{ x = 1 } | Write-AtomicJson -Path $target
        $parsed = Get-Content $target -Raw | ConvertFrom-Json
        $parsed.x | Should -Be 1
    }

    It "produces compact JSON with -Compress" {
        $target = Join-Path $script:JsonTestDir "compact.json"
        Write-AtomicJson -Path $target -InputObject @{ a = 1; b = 2 } -Compress
        $content = (Get-Content $target -Raw).Trim()
        $content | Should -Not -Match "`n"
    }

    It "omits trailing newline with -NoNewline" {
        $target = Join-Path $script:JsonTestDir "nonl.json"
        Write-AtomicJson -Path $target -InputObject @{} -NoNewline
        $content = Get-Content $target -Raw
        $content.EndsWith("`n") | Should -Be $false
    }
}

Describe "Assert-DockerfileCopyPaths" -Tag "Core" {
    BeforeAll {
        $script:DockerTestDir = Join-Path $env:TEMP "Interclaw-DockerCopy-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $script:DockerTestDir -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $script:DockerTestDir "src") -Force
        $null = New-Item -ItemType File -Path (Join-Path $script:DockerTestDir "src" "app.py") -Force
        $null = New-Item -ItemType File -Path (Join-Path $script:DockerTestDir "src" "app.js") -Force
        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        . (Join-Path $corePublic 'Assert-DockerfileCopyPaths.ps1')
    }
    AfterAll {
        if (Test-Path $script:DockerTestDir) { Remove-Item -Recurse -Force $script:DockerTestDir }
    }

    It "passes when all COPY sources exist" {
        $df = Join-Path $script:DockerTestDir "Dockerfile"
        @"
FROM python:3.11
COPY src/app.py /app/
COPY src/ /app/src/
"@ | Set-Content -Path $df -Encoding utf8 -NoNewline
        $result = Assert-DockerfileCopyPaths -RootDir $script:DockerTestDir
        $result.Passed | Should -Be $true
        $result.Failures.Count | Should -Be 0
    }

    It "fails when a COPY source does not exist" {
        $failDir = Join-Path $env:TEMP "Interclaw-DockerCopy-Fail-$(Get-Random)"
        $null = New-Item -ItemType Directory -Path $failDir -Force
        try {
            $df = Join-Path $failDir "Dockerfile"
            @"
FROM python:3.11
COPY missing.py /app/
"@ | Set-Content -Path $df -Encoding utf8 -NoNewline
            $result = Assert-DockerfileCopyPaths -RootDir $failDir
            $result.Passed | Should -Be $false
            $result.Failures.Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item -Recurse -Force $failDir -ErrorAction SilentlyContinue
        }
    }

    It "skips COPY --from= multi-stage references" {
        $df = Join-Path $script:DockerTestDir "Dockerfile3"
        @"
FROM node:18 AS builder
COPY src/app.js /build/
FROM python:3.11
COPY --from=builder /build/app.js /app/
COPY src/app.py /app/
"@ | Set-Content -Path $df -Encoding utf8 -NoNewline
        $result = Assert-DockerfileCopyPaths -RootDir $script:DockerTestDir
        $result.Passed | Should -Be $true
    }

    It "skips absolute and wildcard paths" {
        $df = Join-Path $script:DockerTestDir "Dockerfile4"
        @"
FROM python:3.11
COPY /absolute/path /app/
COPY *.py /app/
COPY src/*.py /app/
"@ | Set-Content -Path $df -Encoding utf8 -NoNewline
        $result = Assert-DockerfileCopyPaths -RootDir $script:DockerTestDir
        $result.Passed | Should -Be $true
    }
}

Describe "Invoke-DockerWithLogging" -Tag "Core" {
    BeforeAll {
        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        . (Join-Path $corePublic 'Invoke-DockerWithLogging.ps1')
    }

    It "returns success for exit code 0" {
        Mock Write-Verbose { }
        $result = Invoke-DockerWithLogging -Command { cmd /c "exit 0" -and "ok" } -OperationLabel "test"
        $result.Success | Should -Be $true
        $result.ExitCode | Should -Be 0
    }

    It "warns on non-zero exit code without -FailOnError" {
        Mock Write-Warning { }
        $result = Invoke-DockerWithLogging -Command { cmd /c "exit 1" } -OperationLabel "failing"
        $result.Success | Should -Be $false
        $result.ExitCode | Should -Be 1
    }

    It "throws on non-zero exit code with -FailOnError" {
        Mock Write-Error { }
        { Invoke-DockerWithLogging -Command { cmd /c "exit 1" } -OperationLabel "critical" -FailOnError } | Should -Throw
    }

    It "uses Write-Debug when -SuppressStderr is set" {
        Mock Write-Debug { }
        $result = Invoke-DockerWithLogging -Command { cmd /c "exit 0" -and "discovery" } -OperationLabel "discovery" -SuppressStderr
        $result.Success | Should -Be $true
    }

    It "returns Output as a string" {
        $result = Invoke-DockerWithLogging -Command { cmd /c "exit 0" -and "output lines" } -OperationLabel "output"
        $result.Output | Should -BeOfType [string]
    }
}

Describe "New-CryptographicToken" -Tag "Core" {
    BeforeAll {
        $corePublic = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\Public'
        . (Join-Path $corePublic 'New-CryptographicToken.ps1')
    }

    It "returns a non-empty string" {
        $token = New-CryptographicToken
        $token | Should -Not -BeNullOrEmpty
        $token | Should -BeOfType [string]
    }

    It "returns a URL-safe token (no + / = or - characters)" {
        $token = New-CryptographicToken
        $token | Should -Not -Match '[+/=-]'
    }

    It "defaults to 32 bytes producing a token of expected length" {
        $token = New-CryptographicToken
        $token.Length | Should -BeGreaterThan 32
    }

    It "accepts custom byte count" {
        $token = New-CryptographicToken -ByteCount 16
        $token | Should -Not -BeNullOrEmpty
    }

    It "produces different values on successive calls" {
        $t1 = New-CryptographicToken
        $t2 = New-CryptographicToken
        $t1 | Should -Not -Be $t2
    }
}

Describe "Convert-PidSafe" -Tag "Core" {
    BeforeAll {
        # Ensure the function is available via module import
        $corePsd1 = Join-Path $PSScriptRoot '..\Modules\SalmonRun.Core\SalmonRun.Core.psd1'
        if (-not (Get-Command 'Convert-PidSafe' -ErrorAction SilentlyContinue)) {
            Import-Module $corePsd1 -Force -ErrorAction SilentlyContinue
        }
        if (-not (Get-Command 'Convert-PidSafe' -ErrorAction SilentlyContinue)) {
            # Fallback: define inline so tests work standalone
            function Convert-PidSafe {
                param([string]$Value)
                $pidNum = 0
                if (-not [string]::IsNullOrWhiteSpace($Value) -and [int]::TryParse($Value.Trim(), [ref]$pidNum) -and $pidNum -gt 0) {
                    return $pidNum
                }
                return $null
            }
        }
    }

    Context "Valid numeric strings" {
        It "returns 123 for '123'" {
            Convert-PidSafe "123" | Should -Be 123
        }
        It "returns 456 for ' 456 '" {
            Convert-PidSafe " 456 " | Should -Be 456
        }
        It "returns 789 for '789'" {
            Convert-PidSafe "789" | Should -Be 789
        }
    }

    Context "Non-numeric strings" {
        It "returns $null for 'coder-abc'" {
            Convert-PidSafe "coder-abc" | Should -Be $null
        }
        It "returns $null for 'session:xyz'" {
            Convert-PidSafe "session:xyz" | Should -Be $null
        }
        It "returns $null for 'abc'" {
            Convert-PidSafe "abc" | Should -Be $null
        }
    }

    Context "Empty and whitespace" {
        It "returns $null for empty string" {
            Convert-PidSafe "" | Should -Be $null
        }
        It "returns $null for whitespace" {
            Convert-PidSafe "  " | Should -Be $null
        }
    }

    Context "Invalid PID values" {
        It "returns $null for '0' (not a valid PID)" {
            Convert-PidSafe "0" | Should -Be $null
        }
        It "returns $null for '-5' (negative)" {
            Convert-PidSafe "-5" | Should -Be $null
        }
    }
}

