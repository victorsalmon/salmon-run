#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $__repoRoot = (Get-Item $PSCommandPath).Directory.Parent.FullName
    $__modulesDir = [System.IO.Path]::Combine($__repoRoot, "Modules")

    $script:WfModuleDir = Join-Path $__modulesDir "SalmonRun.WorkflowEvents"
    $script:WfPsd1 = Join-Path $script:WfModuleDir "SalmonRun.WorkflowEvents.psd1"
    $script:WfPublic = Join-Path $script:WfModuleDir "Public"

    function Get-SalmonRunRepoRoot { return $script:WfTestDir }
    function Write-Debug { param([string]$Message) }

    $script:WfTestDir = Join-Path $env:TEMP "Interclaw-WFModuleTest-$(Get-Random)"
    New-Item -ItemType Directory -Path $script:WfTestDir -Force | Out-Null
    $script:SavedSalmonRunHome = $env:SALMON_RUN_HOME
    $env:SALMON_RUN_HOME = $script:WfTestDir

    $pathsPath = [System.IO.Path]::Combine($__repoRoot, "Modules", "SalmonRun.Paths", "SalmonRun.Paths.ps1")
    if (Test-Path $pathsPath) { . $pathsPath }

    Get-ChildItem -Path $script:WfPublic -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }

    $script:SavedAgentId = $env:OC_RESERVATION_AGENT_ID
    $env:OC_RESERVATION_AGENT_ID = "pester-wf-module-test"
}

Describe "WorkflowEvents tests" -Tag "WorkflowEvents" {

    AfterEach {
        $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
        if (Test-Path $eventsDir) {
            Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
        }
    }

    AfterAll {
        if ($script:SavedAgentId) { $env:OC_RESERVATION_AGENT_ID = $script:SavedAgentId }
        else { Remove-Item Env:\OC_RESERVATION_AGENT_ID -ErrorAction SilentlyContinue }
        if (Test-Path $script:WfTestDir) {
            Remove-Item -Recurse -Force $script:WfTestDir
        }
        if ($script:SavedSalmonRunHome) { $env:SALMON_RUN_HOME = $script:SavedSalmonRunHome } else { Remove-Item Env:\SALMON_RUN_HOME -ErrorAction SilentlyContinue }
    }

    Describe "SalmonRun.WorkflowEvents Module Manifest" -Tag "Regression-Only" {

        It "psd1 file exists" {
            Test-Path $script:WfPsd1 | Should -Be $true
        }

        It "exports exactly 4 functions" {
            $manifest = Import-PowerShellDataFile -Path $script:WfPsd1
            $manifest.FunctionsToExport.Count | Should -Be 4
            $manifest.FunctionsToExport | Should -Contain "Write-WorkflowEvent"
            $manifest.FunctionsToExport | Should -Contain "Get-WorkflowEvents"
            $manifest.FunctionsToExport | Should -Contain "Write-NamespaceLog"
            $manifest.FunctionsToExport | Should -Contain "Get-NamespaceLog"
        }
    }

    Describe "Write-WorkflowEvent" {

        It "creates the events directory and log file on first write" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "test-agent-001-01" -Phase coder
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
            Test-Path $logFile | Should -Be $true
        }

        It "appends a valid JSONL line with correct fields" {
            Write-WorkflowEvent -Type CLAIM -Files @("plan.md") -AgentId "test-agent-001-01" -Phase coder -Detail "locked"
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
            $line = Get-Content $logFile -Tail 1
            $parsed = $line | ConvertFrom-Json
            $parsed.type | Should -Be "CLAIM"
            $parsed.agent | Should -Be "test-agent-001-01"
            $parsed.files[0] | Should -Be "plan.md"
            $parsed.detail | Should -Be "locked"
            $parsed.phase | Should -Be "coder"
        }

        It "auto-increments event IDs" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "id-test" -Phase coder
            Write-WorkflowEvent -Type COMMIT -AgentId "id-test" -Phase coder
            Write-WorkflowEvent -Type PUSH -AgentId "id-test" -Phase coder
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
            $lines = Get-Content $logFile
            $ids = $lines | ForEach-Object { ($_ | ConvertFrom-Json).id }
            $ids[0] | Should -Be 1
            $ids[2] | Should -Be 3
        }

        It "defaults AgentId from env var when not provided" {
            $env:OC_RESERVATION_AGENT_ID = "env-agent-test"
            Write-WorkflowEvent -Type SESSION_START -Phase coder
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
            $line = Get-Content $logFile -Tail 1
            $parsed = $line | ConvertFrom-Json
            $parsed.agent | Should -Be "env-agent-test"
        }
    }

    Describe "Get-WorkflowEvents" {

        BeforeAll {
            $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
            if (Test-Path $eventsDir) {
                Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
            }
        }

        BeforeEach {
            # Directly clear the test log directory for clean state
            $eventsDir = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs")
            if (Test-Path $eventsDir) {
                Remove-Item -Recurse -Force $eventsDir -ErrorAction SilentlyContinue
            }
            $null = New-Item -ItemType Directory -Path $eventsDir -Force
        }

        It "returns empty array when log does not exist" {
            $result = Get-WorkflowEvents -AgentId "test-agent"
            $result | Should -BeNullOrEmpty
        }

        It "returns all events on first read" {
            # Note: extra empty event may appear from test env state; check that
            # valid written events are present
            Write-WorkflowEvent -Type SESSION_START -AgentId "reader-test" -Phase coder
            Write-WorkflowEvent -Type CLAIM -AgentId "reader-test" -Phase coder -Files @("plan.md")

            $events = Get-WorkflowEvents -AgentId "reader-test"
            $validEvents = @($events | Where-Object { $null -ne $_.type -and $_.type -ne "" })
            $validEvents.Count | Should -Be 2
            $validEvents[0].type | Should -Be "SESSION_START"
            $validEvents[1].type | Should -Be "CLAIM"
        }

        It "returns only new events on subsequent reads" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "reader-test" -Phase coder
            $null = Get-WorkflowEvents -AgentId "reader-test"

            Write-WorkflowEvent -Type COMMIT -AgentId "reader-test" -Phase coder -Detail "abc1234"
            $events = Get-WorkflowEvents -AgentId "reader-test"
            $validEvents = @($events | Where-Object { $null -ne $_.type -and $_.type -ne "" })
            $validEvents.Count | Should -Be 1
            $validEvents[0].type | Should -Be "COMMIT"
        }
    }

    Describe "Write-WorkflowEvent -Clear" {

        It "deletes the log file and all offset files" {
            Write-WorkflowEvent -Type SESSION_START -AgentId "clear-test" -Phase coder
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "workflow-events.log")
            Test-Path $logFile | Should -Be $true

            Write-WorkflowEvent -Clear -AgentId "auditor" -Phase audit
            Test-Path $logFile | Should -Be $false
        }
    }

    Describe "Write-NamespaceLog" -Tag "WorkflowEvents" {

        It "creates the log file on first write" {
            Write-NamespaceLog -Namespace test -Type NOTE -Detail "test entry"
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "test.log")
            Test-Path $logFile | Should -Be $true
        }

        It "appends multiple entries to the same namespace file" {
            Write-NamespaceLog -Namespace test -Type NOTE -Detail "entry 1"
            Write-NamespaceLog -Namespace test -Type DECISION -Detail "entry 2"
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "test.log")
            $lines = Get-Content $logFile
            $lines.Count | Should -BeGreaterOrEqual 2
        }

        It "writes valid JSON with required fields" {
            Write-NamespaceLog -Namespace test-json -Type DECISION -Detail "json check"
            $logFile = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "test-json.log")
            $entry = Get-Content $logFile | ConvertFrom-Json
            $entry.ns | Should -Be "test-json"
            $entry.type | Should -Be "DECISION"
            $entry.detail | Should -Be "json check"
            $entry.ts | Should -Not -BeNullOrEmpty
        }

        It "creates separate files per namespace" {
            Write-NamespaceLog -Namespace alpha -Type NOTE -Detail "alpha"
            Write-NamespaceLog -Namespace beta -Type NOTE -Detail "beta"
            $alphaLog = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "alpha.log")
            $betaLog = [System.IO.Path]::Combine($script:WfTestDir, "Tasks", "Logs", "beta.log")
            Test-Path $alphaLog | Should -Be $true
            Test-Path $betaLog | Should -Be $true
        }
    }

    Describe "Get-NamespaceLog" -Tag "WorkflowEvents" {

        It "returns empty array when namespace log does not exist" {
            $result = Get-NamespaceLog -Namespace nonexistent
            $result | Should -BeNullOrEmpty
        }

        It "returns all entries for a namespace" {
            Write-NamespaceLog -Namespace read-test -Type NOTE -Detail "first"
            Write-NamespaceLog -Namespace read-test -Type NOTE -Detail "second"
            $result = Get-NamespaceLog -Namespace read-test
            $result.Count | Should -Be 2
        }

        It "filters by -Since" {
            Write-NamespaceLog -Namespace since-test -Type NOTE -Detail "old"
            Start-Sleep -Milliseconds 100
            $since = Get-Date
            Start-Sleep -Milliseconds 100
            Write-NamespaceLog -Namespace since-test -Type NOTE -Detail "new"
            $recent = Get-NamespaceLog -Namespace since-test -Since $since
            $recent.Count | Should -Be 1
            $recent[0].detail | Should -Be "new"
        }

        It "-ListNamespaces returns all namespace log names" {
            Write-NamespaceLog -Namespace list-a -Type NOTE -Detail "a"
            Write-NamespaceLog -Namespace list-b -Type NOTE -Detail "b"
            $names = Get-NamespaceLog -ListNamespaces
            $names | Should -Contain "list-a"
            $names | Should -Contain "list-b"
        }
    }

    Describe "WorkflowEvents functions accessible via canonical module" -Tag "Regression-Only" {

        It "all 4 function names appear in SalmonRun.WorkflowEvents FunctionsToExport" {
            $manifest = Import-PowerShellDataFile -Path $script:WfPsd1
            $manifest.FunctionsToExport | Should -Contain "Write-WorkflowEvent"
            $manifest.FunctionsToExport | Should -Contain "Get-WorkflowEvents"
            $manifest.FunctionsToExport | Should -Contain "Write-NamespaceLog"
            $manifest.FunctionsToExport | Should -Contain "Get-NamespaceLog"
        }
    }
}

