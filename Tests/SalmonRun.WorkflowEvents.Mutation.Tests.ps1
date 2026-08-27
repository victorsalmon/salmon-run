#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }
#Requires -Version 7.0

<#
.SYNOPSIS
    Mutation tests for SalmonRun.WorkflowEvents boundaries.

.DESCRIPTION
    Targets JSONL serialization, auto-increment ID, offset tracking, and
    append-vs-seek path selection in Write-WorkflowEvent.
#>

BeforeAll {
    $repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__modulesDir = Join-Path $repoRoot 'Modules'

    $script:WfModuleDir = Join-Path $__modulesDir "SalmonRun.WorkflowEvents"
    $script:WfPsd1 = Join-Path $script:WfModuleDir "SalmonRun.WorkflowEvents.psd1"
    $script:WfPublic = Join-Path $script:WfModuleDir "Public"

    function Get-SalmonRunRepoRoot { return $script:WfTestDir }
    function Write-Debug { param([string]$Message) }

    $script:WfTestDir = Join-Path $env:TEMP "Interclaw-WFMutationTest-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:WfTestDir -Force | Out-Null
    $script:SavedSalmonRunHome = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = $script:WfTestDir

    $pathsPath = Join-Path $repoRoot 'Modules' "SalmonRun.Paths" "SalmonRun.Paths.ps1"
    if (Test-Path $pathsPath) { . $pathsPath }

    Get-ChildItem -Path $script:WfPublic -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }

    $script:SavedAgentId = $env:OC_RESERVATION_AGENT_ID
    $env:OC_RESERVATION_AGENT_ID = "pester-wf-mutation-test"
}

AfterAll {
    if ($script:SavedAgentId) { $env:OC_RESERVATION_AGENT_ID = $script:SavedAgentId }
    else { Remove-Item Env:\OC_RESERVATION_AGENT_ID -ErrorAction SilentlyContinue }
    if (Test-Path $script:WfTestDir) {
        Remove-Item -Recurse -Force $script:WfTestDir
    }
    if ($script:SavedSalmonRunHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonRunHome } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
}

# ==============================================================================
# Write-WorkflowEvent — Serialization mutations
# ==============================================================================

Describe "Write-WorkflowEvent serialization mutations" -Tag "WorkflowEvents", "Mutation" {

    AfterEach {
        $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
        if (Test-Path $eventsDir) {
            Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
        }
    }

    It "creates events directory on first write" {
        Write-WorkflowEvent -Type SESSION_START -AgentId "mutation-test-001" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        Test-Path $logFile | Should -Be $true
    }

    It "appends valid JSONL line with required fields" {
        Write-WorkflowEvent -Type CLAIM -Files @("plan.md") -AgentId "mutation-test-002" -Phase coder -Detail "locked"
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $line = Get-Content $logFile -Tail 1
        $parsed = $line | ConvertFrom-Json
        $parsed.type | Should -Be "CLAIM"
        $parsed.agent | Should -Be "mutation-test-002"
        $parsed.files[0] | Should -Be "plan.md"
        $parsed.detail | Should -Be "locked"
        $parsed.phase | Should -Be "coder"
    }

    It "auto-increments event IDs" {
        Write-WorkflowEvent -Type SESSION_START -AgentId "mutation-test-003" -Phase coder
        Write-WorkflowEvent -Type COMMIT -AgentId "mutation-test-003" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $lines = Get-Content $logFile
        $id1 = ($lines[0] | ConvertFrom-Json).id
        $id2 = ($lines[1] | ConvertFrom-Json).id
        $id2 | Should -Be ($id1 + 1)
    }

    It "includes ISO 8601 timestamp" {
        Write-WorkflowEvent -Type RELEASE -AgentId "mutation-test-004" -Phase reviewer
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $rawLine = Get-Content $logFile -Tail 1
        # Check the raw JSONL line contains an ISO 8601 ts field
        $rawLine | Should -Match '"ts":"2026-'
        $rawLine | Should -Match 'T.*Z"'
    }

    It "handles empty files array" {
        Write-WorkflowEvent -Type COMMIT -AgentId "mutation-test-005" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $parsed = Get-Content $logFile -Tail 1 | ConvertFrom-Json
        $parsed.files | Should -BeNullOrEmpty
    }

    It "handles multiple files" {
        Write-WorkflowEvent -Type MOVE -Files @("a.md", "b.md", "c.md") -AgentId "mutation-test-006" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $parsed = Get-Content $logFile -Tail 1 | ConvertFrom-Json
        $parsed.files.Count | Should -Be 3
    }

    It "round-trip: JSON parse of event preserves all fields" {
        Write-WorkflowEvent -Type CLAIM -Files @("test.md") -AgentId "mutation-test-007" -Phase coder -Detail "roundtrip"
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $raw = Get-Content $logFile -Tail 1
        $parsed = $raw | ConvertFrom-Json
        $reparsed = ($parsed | ConvertTo-Json -Compress) | ConvertFrom-Json
        $reparsed.type | Should -Be $parsed.type
        $reparsed.agent | Should -Be $parsed.agent
        $reparsed.id | Should -Be $parsed.id
    }
}

# ==============================================================================
# Write-WorkflowEvent — ID increment mutations
# ==============================================================================

Describe "Write-WorkflowEvent ID increment mutations" -Tag "WorkflowEvents", "Mutation" {

    AfterEach {
        $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
        if (Test-Path $eventsDir) {
            Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
        }
    }

    It "ID starts at 1 for fresh log" {
        Write-WorkflowEvent -Type SESSION_START -AgentId "mutation-test-010" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $parsed = Get-Content $logFile -Tail 1 | ConvertFrom-Json
        $parsed.id | Should -Be 1
    }

    It "IDs are monotonically increasing across 5 writes" {
        1..5 | ForEach-Object {
            Write-WorkflowEvent -Type CLAIM -AgentId "mutation-test-011" -Phase coder
        }
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $lines = Get-Content $logFile
        $ids = $lines | ForEach-Object { ($_ | ConvertFrom-Json).id }
        for ($i = 1; $i -lt $ids.Count; $i++) {
            $ids[$i] | Should -BeGreaterThan $ids[$i - 1]
        }
    }

    It "continues ID from offset file when present" {
        # Write one event to establish the log
        Write-WorkflowEvent -Type SESSION_START -AgentId "mutation-test-012" -Phase coder
        # Manually set offset to simulate prior state
        $offsetsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", ".offsets")
        $null = New-Item -ItemType Directory -Path $offsetsDir -Force
        $offsetPath = Join-Path $offsetsDir ".event-log.offset"
        $offsetJson = @{ lastId = 99; byteOffset = 0 } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($offsetPath, $offsetJson, [System.Text.Encoding]::UTF8)
        # Write another event — should pick up lastId=99 from offset
        Write-WorkflowEvent -Type COMMIT -AgentId "mutation-test-012" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        $lines = Get-Content $logFile
        $lastParsed = $lines[-1] | ConvertFrom-Json
        $lastParsed.id | Should -Be 100
    }
}

# ==============================================================================
# Write-WorkflowEvent — Clear mutations
# ==============================================================================

Describe "Write-WorkflowEvent Clear mutations" -Tag "WorkflowEvents", "Mutation" {

    AfterEach {
        $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
        if (Test-Path $eventsDir) {
            Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
        }
    }

    It "Clear removes the events log file" {
        Write-WorkflowEvent -Type SESSION_START -AgentId "mutation-test-020" -Phase coder
        $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
        Test-Path $logFile | Should -Be $true
        Write-WorkflowEvent -Clear -AgentId "mutation-test-020" -Phase coder
        Test-Path $logFile | Should -Be $false
    }

    It "Clear removes offset files" {
        Write-WorkflowEvent -Type CLAIM -AgentId "mutation-test-021" -Phase coder
        $offsetsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", ".offsets")
        Test-Path $offsetsDir | Should -Be $true
        Write-WorkflowEvent -Clear -AgentId "mutation-test-021" -Phase coder
        $offsetFiles = Get-ChildItem "$offsetsDir/*.offset" -ErrorAction SilentlyContinue
        $offsetFiles | Should -BeNullOrEmpty
    }

    It "Clear recreates events directory" {
        Write-WorkflowEvent -Type SESSION_START -AgentId "mutation-test-022" -Phase coder
        Write-WorkflowEvent -Clear -AgentId "mutation-test-022" -Phase coder
        $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
        Test-Path $eventsDir | Should -Be $true
    }
}
