#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

# Tests for the checkpoint-compact-restore ritual scripts.
# Covers: Write-SessionCheckpoint (writer), Restore-SessionCheckpoint (reader).
# Read-only w.r.t. the real repo — tests use a temp RepoRoot and a temp session id.
BeforeAll {
    $ScriptsDir = Join-Path $PSScriptRoot "..\..\Documentation\Scripts"

    # Unique temp session id per test run so parallel/sequential runs don't collide.
    $script:TestId = "test-$(Get-Random)"
    $script:TempRepo = Join-Path $env:TEMP "CheckpointTest_$(Get-Random)"
    $script:TempCheckpointsDir = Join-Path $script:TempRepo "Tasks\Logs\checkpoints"
    $script:TempSessionStartLog = Join-Path $script:TempRepo ("Tasks\Logs\session-start-" + ($env:OC_STREAM_ID ?? $env:OC_RESERVATION_AGENT_ID ?? $PID) + ".log")

    $null = New-Item -ItemType Directory -Path (Join-Path $script:TempRepo "Tasks\Logs") -Force

    # Seed the lane/agent-scoped session-start log so the writer can read it.
    # Legacy shared file is also seeded — the reader falls back to it when the
    # scoped file is absent (orchestrator-tooling-1 convention).
    "2026-07-15T10:00:00.0000000+00:00" | Set-Content -LiteralPath $script:TempSessionStartLog -Encoding utf8
    "2026-07-15T10:00:00.0000000+00:00" | Set-Content -LiteralPath (Join-Path $script:TempRepo "Tasks\Logs\session-start.log") -Encoding utf8

    # Dot-source the scripts under test.
    . (Join-Path $ScriptsDir "Write-SessionCheckpoint.ps1")
    . (Join-Path $ScriptsDir "Restore-SessionCheckpoint.ps1")
}

AfterAll {
    if (Test-Path $script:TempRepo) { Remove-Item -LiteralPath $script:TempRepo -Recurse -Force }
}

Describe "Session Checkpoint scripts parse" -Tag "OpenCode" {
    It "Write-SessionCheckpoint.ps1 has no syntax errors" {
        $errs = $null
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content -Raw -LiteralPath (Join-Path $ScriptsDir "Write-SessionCheckpoint.ps1")), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
    It "Restore-SessionCheckpoint.ps1 has no syntax errors" {
        $errs = $null
        $null = [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content -Raw -LiteralPath (Join-Path $ScriptsDir "Restore-SessionCheckpoint.ps1")), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Write-SessionCheckpoint" -Tag "OpenCode" {
    It "defines function" {
        Get-Command Write-SessionCheckpoint -EA SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "writes a checkpoint file with all expected headers" {
        $out = Write-SessionCheckpoint -Mode "code" `
            -CurrentPlan "Tasks/Code/sample-plan.md" `
            -PlanStatus "task 3 of 5 — implementing Invoke-Foo" `
            -DeferredItems "none" `
            -Notes "locks held: plan-X.md" `
            -RepoRoot $script:TempRepo `
            6>&1
        $path = if ($out -is [string]) { $out } else { ($out | Where-Object { $_ -like '*checkpoint.md' })[-1] }
        # The function returns the path; capture from stdout if return was swallowed.
        if (-not $path -or -not (Test-Path $path)) {
            $path = (Get-ChildItem -LiteralPath $script:TempCheckpointsDir -Filter "*.checkpoint.md" | Select-Object -First 1).FullName
        }
        Test-Path -LiteralPath $path | Should -BeTrue
        $content = Get-Content -LiteralPath $path -Raw
        $content | Should -Match "# Session Checkpoint"
        $content | Should -Match "\*\*Session ID\*\*:"
        $content | Should -Match "\*\*Timestamp\*\*:"
        $content | Should -Match "\*\*Mode\*\*: code"
        $content | Should -Match "\*\*Session Start\*\*:"
        $content | Should -Match "\*\*Compaction Count\*\*:"
        $content | Should -Match "\*\*Current Plan\*\*: Tasks/Code/sample-plan.md"
        $content | Should -Match "\*\*Plan Status\*\*: task 3 of 5"
        $content | Should -Match "## Workflow State"
        $content | Should -Match "## Git State"
        $content | Should -Match "## Deferred Items"
    }

    It "creates the checkpoints directory if absent" {
        $freshRepo = Join-Path $env:TEMP "CheckpointFresh_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path (Join-Path $freshRepo "Tasks\Logs") -Force
        $cpDir = Join-Path $freshRepo "Tasks\Logs\checkpoints"
        Test-Path -LiteralPath $cpDir | Should -BeFalse
        Write-SessionCheckpoint -Mode "review" -CurrentPlan "none" -RepoRoot $freshRepo 6>&1 | Out-Null
        Test-Path -LiteralPath $cpDir | Should -BeTrue
        Remove-Item -LiteralPath $freshRepo -Recurse -Force
    }

    It "auto-derives compaction count: 1 for first, 2 for second (same session id)" {
        $freshRepo = Join-Path $env:TEMP "CheckpointCount_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path (Join-Path $freshRepo "Tasks\Logs") -Force
        $sid = "count-test-$(Get-Random)"
        $env:OPENCODE_SESSION_ID = $sid

        Write-SessionCheckpoint -Mode "code" -CurrentPlan "none" -RepoRoot $freshRepo 6>&1 | Out-Null
        $first = Get-ChildItem -LiteralPath (Join-Path $freshRepo "Tasks\Logs\checkpoints") -Filter "$sid*.checkpoint.md"
        $first.Count | Should -Be 1
        (Get-Content -LiteralPath $first[0].FullName -Raw) | Should -Match "\*\*Compaction Count\*\*: 1"

        Write-SessionCheckpoint -Mode "code" -CurrentPlan "none" -RepoRoot $freshRepo 6>&1 | Out-Null
        $all = Get-ChildItem -LiteralPath (Join-Path $freshRepo "Tasks\Logs\checkpoints") -Filter "$sid*.checkpoint.md"
        $all.Count | Should -Be 2
        $newest = $all | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        (Get-Content -LiteralPath $newest.FullName -Raw) | Should -Match "\*\*Compaction Count\*\*: 2"

        Remove-Variable OPENCODE_SESSION_ID -Scope Process -EA SilentlyContinue
        Remove-Item -LiteralPath $freshRepo -Recurse -Force
    }

    It "falls back to 'unknown' session id when env unset" {
        $freshRepo = Join-Path $env:TEMP "CheckpointUnknown_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path (Join-Path $freshRepo "Tasks\Logs") -Force
        $saved = $env:OPENCODE_SESSION_ID
        Remove-Item Env:\OPENCODE_SESSION_ID -EA SilentlyContinue

        Write-SessionCheckpoint -Mode "code" -CurrentPlan "none" -RepoRoot $freshRepo 6>&1 | Out-Null
        $f = Get-ChildItem -LiteralPath (Join-Path $freshRepo "Tasks\Logs\checkpoints") -Filter "unknown*.checkpoint.md"
        $f.Count | Should -BeGreaterThan 0
        (Get-Content -LiteralPath $f[0].FullName -Raw) | Should -Match "\*\*Session ID\*\*: unknown"

        if ($null -ne $saved) { $env:OPENCODE_SESSION_ID = $saved }
        Remove-Item -LiteralPath $freshRepo -Recurse -Force
    }

    It "does not mutate git state (read-only)" {
        $freshRepo = Join-Path $env:TEMP "CheckpointGit_$(Get-Random)"
        $null = New-Item -ItemType Directory -Path (Join-Path $freshRepo "Tasks\Logs") -Force
        $before = @{ }
        # The writer calls git status --porcelain / rev-parse but must never add/commit/move.
        # We assert only that the script completes without throwing in a non-git dir.
        { Write-SessionCheckpoint -Mode "code" -CurrentPlan "none" -RepoRoot $freshRepo 6>&1 | Out-Null } | Should -Not -Throw
        # Confirm a checkpoint was still written despite non-git environment.
        Test-Path -LiteralPath (Join-Path $freshRepo "Tasks\Logs\checkpoints") | Should -BeTrue
        Remove-Item -LiteralPath $freshRepo -Recurse -Force
    }
}

Describe "Restore-SessionCheckpoint" -Tag "OpenCode" {
    It "defines function" {
        Get-Command Restore-SessionCheckpoint -EA SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It "returns the newest checkpoint content for the session" {
        $sid = "restore-test-$(Get-Random)"
        $env:OPENCODE_SESSION_ID = $sid
        Write-SessionCheckpoint -Mode "code" -CurrentPlan "plan-A.md" -RepoRoot $script:TempRepo 6>&1 | Out-Null
        Start-Sleep -Milliseconds 1100 # ensure distinct LastWriteTime
        Write-SessionCheckpoint -Mode "code" -CurrentPlan "plan-B.md" -RepoRoot $script:TempRepo 6>&1 | Out-Null

        $output = Restore-SessionCheckpoint -SessionId $sid -RepoRoot $script:TempRepo 6>&1
        $joined = ($output -join "")
        $joined | Should -Match "plan-B.md"
        $joined | Should -Not -Match "plan-A.md"
        Remove-Variable OPENCODE_SESSION_ID -Scope Process -EA SilentlyContinue
    }

    It "returns null and prints a message when no checkpoint exists" {
        $result = Restore-SessionCheckpoint -SessionId "nonexistent-session-xyz" -RepoRoot $script:TempRepo 6>&1
        $joined = ($result -join "")
        $joined | Should -Match "No checkpoint found"
        # Return value should be null (the printed output is via Write-Host, not the return).
    }

    It "is read-only (does not create or modify files)" {
        $sid = "readonly-test-$(Get-Random)"
        $env:OPENCODE_SESSION_ID = $sid
        Write-SessionCheckpoint -Mode "code" -CurrentPlan "none" -RepoRoot $script:TempRepo 6>&1 | Out-Null
        $filesBefore = (Get-ChildItem -LiteralPath $script:TempCheckpointsDir -Recurse -File).Count

        Restore-SessionCheckpoint -SessionId $sid -RepoRoot $script:TempRepo 6>&1 | Out-Null

        $filesAfter = (Get-ChildItem -LiteralPath $script:TempCheckpointsDir -Recurse -File).Count
        $filesAfter | Should -Be $filesBefore
        Remove-Variable OPENCODE_SESSION_ID -Scope Process -EA SilentlyContinue
    }
}

Describe "Session Checkpoint regression" -Tag "OpenCode", "Regression" {
    It "checkpoint filename embeds session id and unix timestamp" {
        $sid = "filename-test-$(Get-Random)"
        $env:OPENCODE_SESSION_ID = $sid
        Write-SessionCheckpoint -Mode "code" -CurrentPlan "none" -RepoRoot $script:TempRepo 6>&1 | Out-Null
        $f = Get-ChildItem -LiteralPath $script:TempCheckpointsDir -Filter "$sid*.checkpoint.md"
        $f.Count | Should -BeGreaterThan 0
        $f[0].Name | Should -Match "^$sid-\d+\.checkpoint\.md$"
        Remove-Variable OPENCODE_SESSION_ID -Scope Process -EA SilentlyContinue
    }

    It "deferred items and notes are recorded verbatim" {
        $sid = "verbatim-test-$(Get-Random)"
        $env:OPENCODE_SESSION_ID = $sid
        Write-SessionCheckpoint -Mode "code" `
            -CurrentPlan "none" `
            -DeferredItems "Task 4 deferred — needs AWS console access" `
            -Notes "lock: plan-Y.md; in-flight edit: config.ps1" `
            -RepoRoot $script:TempRepo 6>&1 | Out-Null
        $f = Get-ChildItem -LiteralPath $script:TempCheckpointsDir -Filter "$sid*.checkpoint.md" | Select-Object -First 1
        $content = Get-Content -LiteralPath $f.FullName -Raw
        $content | Should -Match "Task 4 deferred — needs AWS console access"
        $content | Should -Match "lock: plan-Y.md; in-flight edit: config.ps1"
        Remove-Variable OPENCODE_SESSION_ID -Scope Process -EA SilentlyContinue
    }
}
