#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#
# DEPRECATED 2026-06-02 (alignment audit Domain 5):
#   This test file dot-sources the old `SalmonRun.Core\SalmonRun.Core.ps1` and
#   `SalmonRun.Core\Public\Write-WorkflowEvent.ps1` paths, but the WorkflowEvents
#   functions were extracted into a dedicated `SalmonRun.WorkflowEvents` module
#   (per AGENTS.md PowerShell Modules table). The canonical test file is
#   `SalmonRun.WorkflowEvents.Tests.ps1` in this directory; it uses the correct
#   module paths and the same set of behavioural assertions. This file is
#   preserved as historical documentation per AGENTS.md "Script Deprecation
#   Protocol" and is skipped via -Skip to avoid false failures.
#
#   If you need to re-enable these tests, port them to use the
#   `SalmonRun.WorkflowEvents` module (Import-Module by .psd1) and update the
#   Test-Path guards below.

Describe "WorkflowEvents (DEPRECATED - see SalmonRun.WorkflowEvents.Tests.ps1)" -Tag "Core", "Deprecated" -Skip {
    BeforeAll {
        $corePath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\SalmonRun.Core.ps1'
        . $corePath
        $writePath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Write-WorkflowEvent.ps1'
        $readPath = Join-Path $PSScriptRoot '..\..\..\Orchestrator\Modules\SalmonRun.Core\Public\Get-WorkflowEvents.ps1'
        if (Test-Path $writePath) { . $writePath }
        if (Test-Path $readPath) { . $readPath }

        $script:WF_TestDir = Join-Path $env:TEMP "Interclaw-WFTest-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:WF_TestDir -Force | Out-Null

        $script:WF_SavedRepoRoot = $script:CachedRepoRoot
        $script:CachedRepoRoot = $script:WF_TestDir

        $script:WF_SavedAgentId = $env:OC_RESERVATION_AGENT_ID
    }

    AfterEach {
        $eventsDir = Join-Path $script:WF_TestDir "Tasks" "Logs"
        if (Test-Path $eventsDir) {
            Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
        }
        $env:OC_RESERVATION_AGENT_ID = $script:WF_SavedAgentId
    }

    AfterAll {
        $script:CachedRepoRoot = $script:WF_SavedRepoRoot
        if ($script:WF_SavedAgentId) { $env:OC_RESERVATION_AGENT_ID = $script:WF_SavedAgentId }
        else { Remove-Item Env:\OC_RESERVATION_AGENT_ID -ErrorAction SilentlyContinue }
        if (Test-Path $script:WF_TestDir) {
            Remove-Item -Recurse -Force $script:WF_TestDir -ErrorAction SilentlyContinue
        }
    }

    Context "Write-WorkflowEvent" -Tag "Core" {
        It "creates the events directory and log file on first write" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            Test-Path $logFile | Should -Be $true
        }

        It "appends a valid JSONL line with correct fields" {
            Write-WorkflowEvent -Type CLAIM -Files @("plan.md") -AgentId "test-agent-001-01" -Phase coder -Detail "locked"
            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            $line = Get-Content $logFile -Tail 1
            $parsed = $line | ConvertFrom-Json
            $parsed.type | Should -Be "CLAIM"
            $parsed.agent | Should -Be "test-agent-001-01"
            $parsed.phase | Should -Be "coder"
            $parsed.files[0] | Should -Be "plan.md"
            $parsed.detail | Should -Be "locked"
            $parsed.id | Should -BeGreaterThan 0
            $parsed.ts | Should -Not -BeNullOrEmpty
        }

        It "auto-increments event IDs" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            Write-WorkflowEvent -Type COMMIT -AgentId "test-agent-001-01" -Phase coder
            Write-WorkflowEvent -Type PUSH -AgentId "test-agent-001-01" -Phase coder
            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            $lines = Get-Content $logFile
            $ids = $lines | ForEach-Object { ($_ | ConvertFrom-Json).id }
            $ids[0] | Should -Be 1
            $ids[1] | Should -Be 2
            $ids[2] | Should -Be 3
        }

        It "supports empty Files array" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            $line = Get-Content $logFile -Tail 1
            $parsed = $line | ConvertFrom-Json
            $parsed.files.Count | Should -Be 0
        }

        It "defaults AgentId from env var when not provided" {
            $env:OC_RESERVATION_AGENT_ID = "env-agent-001-01"
            Write-WorkflowEvent -Type SESSION_START -Phase coder
            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            $line = Get-Content $logFile -Tail 1
            $parsed = $line | ConvertFrom-Json
            $parsed.agent | Should -Be "env-agent-001-01"
        }
    }

    Context "Write-WorkflowEvent -Clear" -Tag "Core" {
        It "deletes the log file and all offset files" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            Write-WorkflowEvent -Type COMMIT -AgentId "test-agent-001-01" -Phase coder

            $offsetsDir = Join-Path $script:WF_TestDir "Tasks" "Logs" ".offsets"
            New-Item -ItemType Directory -Path $offsetsDir -Force | Out-Null
            "42" | Out-File -FilePath (Join-Path $offsetsDir "test-agent-001-01.offset") -Encoding utf8 -NoNewline

            Write-WorkflowEvent -Clear -AgentId "test-agent-001-01" -Phase audit

            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            Test-Path $logFile | Should -Be $false

            $remainingOffsets = Get-ChildItem "$offsetsDir/*.offset" -ErrorAction SilentlyContinue
            $remainingOffsets | Should -BeNullOrEmpty
        }

        It "does not throw when log does not exist" {
            { Write-WorkflowEvent -Clear -AgentId "test-agent-001-01" -Phase audit } | Should -Not -Throw
        }

        It "creates the events directory after clearing" {
            Write-WorkflowEvent -Clear -AgentId "test-agent-001-01" -Phase audit
            $eventsDir = Join-Path $script:WF_TestDir "Tasks" "Logs"
            Test-Path $eventsDir | Should -Be $true
        }
    }

    Context "Get-WorkflowEvents" -Tag "Core" {
        It "returns empty array when log does not exist" {
            $result = Get-WorkflowEvents -AgentId "test-agent-001-01"
            $result | Should -BeNullOrEmpty
        }

        It "returns all events on first read" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            Write-WorkflowEvent -Type CLAIM -AgentId "test-agent-001-01" -Phase coder -Files @("plan.md")

            $events = Get-WorkflowEvents -AgentId "test-agent-001-01"
            $events.Count | Should -Be 2
            $events[0].type | Should -Be "SESSION_START"
            $events[1].type | Should -Be "CLAIM"
        }

        It "returns only new events on subsequent reads" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            $null = Get-WorkflowEvents -AgentId "test-agent-001-01"

            Write-WorkflowEvent -Type COMMIT -AgentId "test-agent-001-01" -Phase coder -Detail "abc1234"
            $events = Get-WorkflowEvents -AgentId "test-agent-001-01"
            $events.Count | Should -Be 1
            $events[0].type | Should -Be "COMMIT"
        }

        It "returns empty array when no new events exist" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            $null = Get-WorkflowEvents -AgentId "test-agent-001-01"
            $events = Get-WorkflowEvents -AgentId "test-agent-001-01"
            $events | Should -BeNullOrEmpty
        }

        It "maintains independent offsets per agent" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "agent-a" -Phase coder
            Write-WorkflowEvent -Type COMMIT -AgentId "agent-a" -Phase coder
            Write-WorkflowEvent -Type SESSION_START -AgentId "agent-b" -Phase coder

            $null = Get-WorkflowEvents -AgentId "agent-a"
            $null = Get-WorkflowEvents -AgentId "agent-b"

            Write-WorkflowEvent -Type PUSH -AgentId "agent-a" -Phase coder

            $eventsA = Get-WorkflowEvents -AgentId "agent-a"
            $eventsA.Count | Should -Be 1
            $eventsA[0].type | Should -Be "PUSH"

            $eventsB = Get-WorkflowEvents -AgentId "agent-b"
            $eventsB.Count | Should -Be 1
            $eventsB[0].type | Should -Be "PUSH"
        }

        It "handles -Clear by delegating to Write-WorkflowEvent" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            $result = Get-WorkflowEvents -AgentId "test-agent-001-01" -Clear
            $result | Should -BeNullOrEmpty

            $logFile = Join-Path $script:WF_TestDir "Tasks" "Logs" "workflow-events.log"
            Test-Path $logFile | Should -Be $false
        }
    }
}
