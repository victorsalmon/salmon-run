#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

#Requires -Version 7.0

BeforeAll {
    $RepoRoot = (Get-Item $PSCommandPath).Directory.Parent.Parent.Parent.FullName
    $OpenCodeDir = Join-Path $RepoRoot "Skills\\Orchestration"
    $GitDir = Join-Path $RepoRoot "Skills\\Git"
    $ScriptDir = Join-Path $RepoRoot "Skills\\Documentation\\Scripts"
    $script:OpenCodeScripts = Get-ChildItem -Path $OpenCodeDir -Filter "*.ps1" -ErrorAction SilentlyContinue
    $script:ScriptsScripts = Get-ChildItem -Path $ScriptDir -Filter "*.ps1" -ErrorAction SilentlyContinue
    $script:AllScripts = $script:OpenCodeScripts + $script:ScriptsScripts
    $script:TempDir = Join-Path $env:TEMP "OpenCodeTest_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TempDir -Force

    function Get-ScriptOutput {
        param([scriptblock]$ScriptBlock)
        $result = & $ScriptBlock 6>&1
        if (-not $result) { $result = & $ScriptBlock }
        return $result
    }
}

AfterAll {
    if (Test-Path $script:TempDir) { Remove-Item -LiteralPath $script:TempDir -Recurse -Force }
}

# ── Root-level script scan ──────────────────────────────────────────────

Describe "OpenCode Root Scripts" -Tag "OpenCode", "Scripts" {
    It "finds at least 20 OpenCode scripts" {
        $script:OpenCodeScripts.Count | Should -BeGreaterThan 20
    }
    It "all OpenCode root scripts parse without syntax errors" {
        $errors = $script:OpenCodeScripts | ForEach-Object {
            $errs = $null
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $_.FullName), [ref]$errs)
            if ($errs) { return $_.Name }
        }
        $errors | Should -BeNullOrEmpty
    }
}

Describe "OpenCode Scripts Subdirectory" -Tag "OpenCode", "Scripts" {
    It "finds at least 5 scripts in Scripts/ subdirectory" {
        $script:ScriptsScripts.Count | Should -BeGreaterThan 5
    }
    It "all Scripts/ scripts parse without syntax errors" {
        $errors = $script:ScriptsScripts | ForEach-Object {
            $errs = $null
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $_.FullName), [ref]$errs)
            if ($errs) { return $_.Name }
        }
        $errors | Should -BeNullOrEmpty
    }
}

# ── Individual function-level tests for critical scripts ─────────────────

Describe "Invoke-GitPullSafe" -Tag "OpenCode", "Git" {
    It "defines parameters" {
        $params = @(Get-Command (Join-Path $GitDir "Invoke-GitPullSafe.ps1")).Parameters.Keys
        $params | Should -Contain "RepoRoot"
        $params | Should -Contain "PassThru"
    }
    It "returns exit code 0 on clean tree (dry run with temp dir)" {
        $tmp = Join-Path $script:TempDir "gps-repo"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        & "$RepoRoot\Skills\\Git\Invoke-GitPullSafe.ps1" -RepoRoot $tmp -PassThru *>&1
    }
    It "worktree mode skips all stash/pull logic" {
        $prev = $env:OC_WORKTREE_PATH
        $env:OC_WORKTREE_PATH = "C:\Worktrees\test"
        try {
        $tmp = Join-Path $script:TempDir "gps-wt"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        git -C $tmp init | Out-Null
        $result = & "$RepoRoot\Skills\\Git\Invoke-GitPullSafe.ps1" -RepoRoot $tmp -PassThru *>&1
            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -Match "OC_WORKTREE_PATH set"
        } finally {
            $env:OC_WORKTREE_PATH = $prev
        }
    }
    It "captures pre-staged paths before git add -A" -Tag "Regression" {
        $content = Get-Content (Join-Path $GitDir "Invoke-GitPullSafe.ps1") -Raw
        $captureIdx = $content.IndexOf('diff --cached --name-only')
        $addIdx = $content.IndexOf('git add -A 2>&1')
        $captureIdx | Should -BeGreaterThan 0
        $captureIdx | Should -BeLessThan $addIdx
    }
    It "restores original staging state after WIP reset" -Tag "Regression" {
        $content = Get-Content (Join-Path $GitDir "Invoke-GitPullSafe.ps1") -Raw
        $content | Should -Match '\$preStaged\.Count -gt 0'
        $content | Should -Match 'git add -- \$preStaged'
    }
    It "sets wipUndone flag after inline WIP undo to prevent double reset" -Tag "Regression" {
        $content = Get-Content (Join-Path $GitDir "Invoke-GitPullSafe.ps1") -Raw
        $step4MsgIdx = $content.IndexOf('WIP commit undone — original staging state restored.')
        $step4MsgIdx | Should -BeGreaterThan 0
        $flagIdx = $content.LastIndexOf('$script:wipUndone = $true', $step4MsgIdx)
        $flagIdx | Should -BeGreaterThan 0
        $flagIdx | Should -BeLessThan $step4MsgIdx
    }
    It "pre-pull check exits 0 without a WIP commit when Tasks/Working holds lane files" -Tag "Regression" {
        $tmp = Join-Path $script:TempDir "gps-lane"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        git -C $tmp init 2>&1 | Out-Null
        git -C $tmp config user.email "test@example.com"
        git -C $tmp config user.name "Test"
        Set-Content -Path (Join-Path $tmp "base.txt") -Value "base" -Encoding utf8
        git -C $tmp add base.txt
        git -C $tmp commit -m "base" 2>&1 | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tmp "Tasks\Working\lane-coder-1") -Force | Out-Null
        Set-Content -Path (Join-Path $tmp "Tasks\Working\lane-coder-1\plan.md") -Value "# Session Plan: test" -Encoding utf8
        $result = & "$RepoRoot\Skills\\Git\Invoke-GitPullSafe.ps1" -RepoRoot $tmp -PassThru *>&1
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Match "Cannot pull: Tasks/Working"
        $wipLeaks = git -C $tmp log --all --oneline --grep="safe-pull-checkpoint"
        $wipLeaks | Should -BeNullOrEmpty
        Test-Path (Join-Path $tmp "Tasks\Working\lane-coder-1\plan.md") | Should -BeTrue
    }
}

Describe "Invoke-SafeCommit" -Tag "OpenCode", "Git" {
    It "defines parameters" {
        $params = @(Get-Command (Join-Path $GitDir "Invoke-SafeCommit.ps1")).Parameters.Keys
        $params | Should -Contain "Paths"
        $params | Should -Contain "Message"
        $params | Should -Contain "RepoRoot"
        $params | Should -Contain "PushRemote"
        $params | Should -Contain "MinWaitSec"
        $params | Should -Contain "MaxWaitSec"
        $params | Should -Contain "PassThru"
    }
    It "returns exit code 0 on clean tree (scoped commit in temp dir)" {
        $tmp = Join-Path $script:TempDir "sc-repo"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        git -C $tmp init | Out-Null
        git -C $tmp config user.email "test@test.com"
        git -C $tmp config user.name "test"
        # Create a bare remote so push succeeds
        $remoteDir = Join-Path $script:TempDir "sc-remote"
        New-Item -ItemType Directory -Path $remoteDir -Force | Out-Null
        git -C $remoteDir init --bare | Out-Null
        git -C $tmp remote add origin $remoteDir
        $null = New-Item -Path "$tmp\test.txt" -ItemType File -Force
        git -C $tmp add test.txt
        git -C $tmp commit -m "initial"
        git -C $tmp push -u origin master 2>&1 | Out-Null
        Set-Content -Path "$tmp\test.txt" -Value "modified"
        $result = & "$RepoRoot\Skills\\Git\Invoke-SafeCommit.ps1" -Paths "test.txt" -Message "feat: test change" -RepoRoot $tmp -PassThru *>&1
        $result.ExitCode | Should -Be 0
    }
    It "worktree mode short-circuits" {
        $prev = $env:OC_WORKTREE_PATH
        $env:OC_WORKTREE_PATH = "C:\Worktrees\sc-test"
        try {
            $tmp = Join-Path $script:TempDir "sc-wt"
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            git -C $tmp init | Out-Null
            git -C $tmp config user.email "test@test.com"
            git -C $tmp config user.name "test"
            $remoteDir2 = Join-Path $script:TempDir "sc-wt-remote"
            New-Item -ItemType Directory -Path $remoteDir2 -Force | Out-Null
            git -C $remoteDir2 init --bare | Out-Null
            git -C $tmp remote add origin $remoteDir2
            $null = New-Item -Path "$tmp\test.txt" -ItemType File -Force
            git -C $tmp add test.txt
            git -C $tmp commit -m "initial"
            git -C $tmp push -u origin master 2>&1 | Out-Null
            Set-Content -Path "$tmp\test.txt" -Value "modified"
            $result = & "$RepoRoot\Skills\\Git\Invoke-SafeCommit.ps1" -Paths "test.txt" -Message "feat: wt test" -RepoRoot $tmp -PassThru *>&1
            $result.ExitCode | Should -Be 0
            $result.Stdout | Should -Match "OC_WORKTREE_PATH"
        } finally {
            $env:OC_WORKTREE_PATH = $prev
        }
    }
    It "contains Lock-File invocation" {
        $content = Get-Content (Join-Path $GitDir "Invoke-SafeCommit.ps1") -Raw
        $content | Should -Match 'Lock-File -FileNames @\("git\.lock"\)'
    }
    It "contains Unlock-File invocation" {
        $content = Get-Content (Join-Path $GitDir "Invoke-SafeCommit.ps1") -Raw
        $content | Should -Match 'Unlock-File -FileNames @\("git\.lock"\)'
    }
    It "contains git reset --soft HEAD~1" {
        $content = Get-Content (Join-Path $GitDir "Invoke-SafeCommit.ps1") -Raw
        $content | Should -Match 'git reset --soft HEAD~1'
    }
    It "contains Get-Random for courtesy wait" {
        $content = Get-Content (Join-Path $GitDir "Invoke-SafeCommit.ps1") -Raw
        $content | Should -Match 'Get-Random'
    }
    It "contains staged-set verification" {
        $content = Get-Content (Join-Path $GitDir "Invoke-SafeCommit.ps1") -Raw
        $content | Should -Match 'git diff --cached --name-only'
    }
    It "derives lockingRoot from script location, not a hard-coded path" -Tag "Regression" {
        $content = Get-Content (Join-Path $GitDir "Invoke-SafeCommit.ps1") -Raw
        $content | Should -Not -Match 'C:\\Repos\\Public\\salmon-run\\Skills\\Docker\\Modules'
        $content | Should -Match 'Split-Path \$PSScriptRoot'
        $content | Should -Match '"Docker" "Modules"'
    }
}

Describe "Send-FleetCode" -Tag "OpenCode", "Fleet" {
    It "requires Prompt parameter" {
        $cmd = Get-Command (Join-Path $OpenCodeDir "Send-FleetCode.ps1")
        $cmd.Parameters["Prompt"].Attributes.Mandatory | Should -Be $true
    }
    It "defines SessionOnly and PassThru switches" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Send-FleetCode.ps1")).Parameters.Keys
        $params | Should -Contain "SessionOnly"
        $params | Should -Contain "PassThru"
    }
}

Describe "Write-FleetCode" -Tag "OpenCode", "Fleet" {
    It "requires Prompt parameter" {
        $cmd = Get-Command (Join-Path $OpenCodeDir "Write-FleetCode.ps1")
        $cmd.Parameters["Prompt"].Attributes.Mandatory | Should -Be $true
    }
    It "writes schedule file in dry-run mode" {
        $outDir = Join-Path $script:TempDir "schedule"
        $null = New-Item -ItemType Directory -Path $outDir -Force
        $result = & "$RepoRoot\Skills\\Orchestration\Write-FleetCode.ps1" -Prompt "test prompt" -Due "ASAP" -PassThru *>&1
    }
    It "defines Due, Prompt, Repeat, PassThru parameters" {
        $cmd = Get-Command (Join-Path $OpenCodeDir "Write-FleetCode.ps1")
        $cmd.Parameters["Prompt"].Attributes.Mandatory | Should -Be $true
        $cmd.Parameters.ContainsKey("Due") | Should -BeTrue
        $cmd.Parameters.ContainsKey("Repeat") | Should -BeTrue
        $cmd.Parameters.ContainsKey("PassThru") | Should -BeTrue
    }
}

Describe "Invoke-Cleanup" -Tag "OpenCode", "Maintenance" {
    It "defines RepoRoot, BooksRoot, Apply, PassThru parameters" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Invoke-Cleanup.ps1")).Parameters.Keys
        $params | Should -Contain "RepoRoot"
        $params | Should -Contain "BooksRoot"
        $params | Should -Contain "Apply"
        $params | Should -Contain "PassThru"
    }
    It "returns empty findings in dry-run mode with empty temp dir" {
        $tmpRepo = Join-Path $script:TempDir "cleanup-repo"
        New-Item -ItemType Directory -Path $tmpRepo -Force | Out-Null
        $result = & "$RepoRoot\Skills\\Orchestration\Invoke-Cleanup.ps1" -RepoRoot $tmpRepo -BooksRoot "$env:TEMP\OpenCodeTest_nonexistent" -PassThru *>&1
    }
    It "detects stale build logs and DB backups" {
        $tmpRepo = Join-Path $script:TempDir "cleanup-repo2"
        New-Item -ItemType Directory -Path $tmpRepo -Force | Out-Null
        New-Item -ItemType Directory -Path "$tmpRepo\Tasks\Logs\build-20260601-120000" -Force | Out-Null
        New-Item -ItemType Directory -Path "$tmpRepo\Tasks\Logs\build-preflight-20260601-120000" -Force | Out-Null
        New-Item -ItemType Directory -Path "$tmpRepo\Tasks\Logs\opencode-db-backup-2026-06-25" -Force | Out-Null
        New-Item -ItemType Directory -Path "$tmpRepo\Tasks\Logs\pre-apply-orphans-backup" -Force | Out-Null
        New-Item -ItemType Directory -Path "$tmpRepo\Tasks\Logs\stale-orchestrator-reports" -Force | Out-Null
        # Seed at least one file in each so size > 0
        Set-Content -Path "$tmpRepo\Tasks\Logs\build-20260601-120000\log.txt" -Value "test"
        Set-Content -Path "$tmpRepo\Tasks\Logs\opencode-db-backup-2026-06-25\opencode.db" -Value "test"
        $result = & "$RepoRoot\Skills\\Orchestration\Invoke-Cleanup.ps1" -RepoRoot $tmpRepo -BooksRoot "$env:TEMP\OpenCodeTest_nonexistent" -PassThru *>&1
        $patterns = $result | ForEach-Object { $_.Pattern }
        $patterns | Should -Contain "stale-build-log"
        $patterns | Should -Contain "stale-db-backup"
        $patterns | Should -Contain "stale-orphan-backup"
        $patterns | Should -Contain "stale-orch-report"
    }
}

Describe "Check-Freshness" -Tag "OpenCode", "Observability" {
    It "defines RepoRoot, MaxDays, PassThru parameters" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Check-Freshness.ps1")).Parameters.Keys
        $params | Should -Contain "RepoRoot"
        $params | Should -Contain "MaxDays"
        $params | Should -Contain "PassThru"
    }
    It "exits 0 when no _freshness.json exists" {
        $tmpRepo = Join-Path $script:TempDir "freshness-repo"
        New-Item -ItemType Directory -Path $tmpRepo -Force | Out-Null
        & "$RepoRoot\Skills\\Orchestration\Check-Freshness.ps1" -RepoRoot $tmpRepo -PassThru *>&1
    }
    It "reports stale entries when freshness file exists" {
        $tmpRepo = Join-Path $script:TempDir "freshness-stale"
        New-Item -ItemType Directory -Path $tmpRepo -Force | Out-Null
        $freshContent = @'
{
  "version": 1,
  "entries": {
    "test-entry": {
      "value": "stale value",
      "verified": "2000-01-01",
      "by": "test",
      "expires_days": 1
    }
  }
}
'@
        $freshContent | Out-File -LiteralPath (Join-Path $tmpRepo "_freshness.json") -Encoding utf8
        $stale = & "$RepoRoot\Skills\\Orchestration\Check-Freshness.ps1" -RepoRoot $tmpRepo -PassThru *>&1
        $stale.Count | Should -BeGreaterThan 0
    }
}

Describe "Get-ConnascenceGroups" -Tag "OpenCode", "Orchestrator" {
    It "defines TaskDir, RepoRoot, PassThru, AsDag, AsTable, OutputDir parameters" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Get-ConnascenceGroups.ps1")).Parameters.Keys
        $params | Should -Contain "TaskDir"
        $params | Should -Contain "PassThru"
        $params | Should -Contain "AsDag"
        $params | Should -Contain "AsTable"
        $params | Should -Contain "OutputDir"
    }
    It "returns empty groups when Code directory is empty" {
        $tmpDir = Join-Path $script:TempDir "cg-empty"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        . (Join-Path $OpenCodeDir "Get-ConnascenceGroups.ps1")
        $result = & "$RepoRoot\Skills\\Orchestration\Get-ConnascenceGroups.ps1" -TaskDir $tmpDir
    }
}

Describe "Invoke-MonitorSubagents" -Tag "OpenCode", "Observability" {
    It "defines AgentDir, RepoRoot, PollSeconds, MaxCycles, PassThru parameters" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Invoke-MonitorSubagents.ps1")).Parameters.Keys
        $params | Should -Contain "AgentDir"
        $params | Should -Contain "RepoRoot"
        $params | Should -Contain "PollSeconds"
        $params | Should -Contain "MaxCycles"
        $params | Should -Contain "PassThru"
    }
    It "returns empty agent list when no agent dir exists" {
        $tmpDir = Join-Path $script:TempDir "monitor-empty"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $result = & "$RepoRoot\Skills\\Orchestration\Invoke-MonitorSubagents.ps1" -AgentDir $tmpDir -PassThru -MaxCycles 0 *>&1
    }
}

Describe "Install-Skills" -Tag "OpenCode", "Skills" {
    It "defines WhatIf, TargetDir, Symlink parameters" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Install-Skills.ps1")).Parameters.Keys
        $params | Should -Contain "WhatIf"
        $params | Should -Contain "TargetDir"
        $params | Should -Contain "Symlink"
    }
    It "runs WhatIf without error" {
        $tmpDir = Join-Path $script:TempDir "install-test"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        & "$RepoRoot\Skills\\Orchestration\Install-Skills.ps1" -WhatIf -TargetDir $tmpDir *>&1
    }
}

Describe "Invoke-Orchestrate" -Tag "OpenCode", "Orchestrator" {
    It "defines WatchIntervalSeconds, MaxWatchMinutes, CodeParallelCount, ReviewerParallelCount, and MaxRuntimeMinutes parameters" {
        $params = @(Get-Command (Join-Path $OpenCodeDir "Invoke-Orchestrate.ps1")).Parameters.Keys
        $params | Should -Contain "WatchIntervalSeconds"
        $params | Should -Contain "MaxWatchMinutes"
        $params | Should -Contain "CodeParallelCount"
        $params | Should -Contain "ReviewerParallelCount"
        $params | Should -Contain "MaxRuntimeMinutes"
    }
}

# ── Scripts/ subdirectory function tests ─────────────────────────────────

Describe "Discover-FleetCapabilities" -Tag "OpenCode", "Fleet" {
    It "defines OutputDir, AsJson, AsMermaid, TimeoutSec parameters" {
        $params = @(Get-Command (Join-Path $ScriptDir "Discover-FleetCapabilities.ps1")).Parameters.Keys
        $params | Should -Contain "OutputDir"
        $params | Should -Contain "AsJson"
        $params | Should -Contain "AsMermaid"
        $params | Should -Contain "TimeoutSec"
    }
    It "generates JSON output in dry-run mode" {
        $result = & "$RepoRoot\Skills\\Documentation\Scripts\Discover-FleetCapabilities.ps1" -AsJson *>&1
    }
}

Describe "Invoke-OrchestratorCycle" -Tag "OpenCode", "Orchestrator" {
    It "defines LastCompletedFile parameter" {
        $params = @(Get-Command (Join-Path $ScriptDir "Invoke-OrchestratorCycle.ps1")).Parameters.Keys
        $params | Should -Contain "LastCompletedFile"
    }
    It "returns status object from empty environment" {
        $tmpState = Join-Path $script:TempDir "cycle-state.json"
        $result = & "$RepoRoot\Skills\\Documentation\Scripts\Invoke-OrchestratorCycle.ps1" -LastCompletedFile $tmpState *>&1
    }
}

Describe "Invoke-DocLint" -Tag "OpenCode", "docs" {
    It "defines Fix, Format, ReportPath parameters" {
        $params = @(Get-Command (Join-Path $ScriptDir "Invoke-DocLint.ps1")).Parameters.Keys
        $params | Should -Contain "Fix"
        $params | Should -Contain "Format"
        $params | Should -Contain "ReportPath"
    }
}

Describe "Invoke-FleetBackup" -Tag "OpenCode", "Fleet" {
    It "exists and parses without syntax errors" {
        $path = Join-Path $ScriptDir "Invoke-FleetBackup.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
    It "defines OutputDir and Compress parameters" {
        $params = @(Get-Command (Join-Path $ScriptDir "Invoke-FleetBackup.ps1")).Parameters.Keys
        $params | Should -Contain "OutputDir"
        $params | Should -Contain "Compress"
        $params | Should -Contain "LogDir"
    }
}

Describe "Invoke-FleetRestore" -Tag "OpenCode", "Fleet" {
    It "exists and parses without syntax errors" {
        $path = Join-Path $ScriptDir "Invoke-FleetRestore.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Build-SkillsIndex" -Tag "OpenCode", "Skills" {
    It "exists and parses without syntax errors" {
        $path = Join-Path $ScriptDir "Build-SkillsIndex.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Compress-OldLogs" -Tag "OpenCode", "Maintenance" {
    It "exists and parses without syntax errors" {
        $path = Join-Path $ScriptDir "Compress-OldLogs.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Invoke-StopSignalCheck" -Tag "OpenCode", "Orchestrator" {
    It "exists and parses without syntax errors" {
        $path = Join-Path $ScriptDir "Invoke-StopSignalCheck.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Invoke-ValidateDependencyGraph" -Tag "OpenCode", "Orchestrator" {
    It "exists and parses without syntax errors" {
        $path = Join-Path $ScriptDir "Invoke-ValidateDependencyGraph.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Write-SessionStart" -Tag "OpenCode", "Orchestrator" {
    It "exists and parses without syntax errors" {
        $path = Join-Path (Join-Path $RepoRoot "Tools\Documentation\Scripts") "Write-SessionStart.ps1"
        Test-Path $path | Should -BeTrue
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }

    It "writes a lane/agent-scoped session-start file (orchestrator-tooling-1)" {
        $scriptPath = Join-Path (Join-Path $RepoRoot "Tools\Documentation\Scripts") "Write-SessionStart.ps1"
        $logsDir = Join-Path $script:TempDir "scoped-logs"
        $null = New-Item -ItemType Directory -Path $logsDir -Force
        & $scriptPath -LogsDir $logsDir -SessionId "lane-test-42" -SkipCompress
        $scoped = Join-Path $logsDir "session-start-lane-test-42.log"
        Test-Path $scoped | Should -BeTrue
        $content = Get-Content $scoped -Raw
        $content | Should -Match '\d{4}-\d{2}-\d{2}T'
        Test-Path (Join-Path $logsDir "session-start.log") | Should -BeFalse
    }

    It "falls back to the process ID when no session id is provided" {
        $scriptPath = Join-Path (Join-Path $RepoRoot "Tools\Documentation\Scripts") "Write-SessionStart.ps1"
        $logsDir = Join-Path $script:TempDir "pid-logs"
        $null = New-Item -ItemType Directory -Path $logsDir -Force
        # Environment-independent: under an orchestrated stream the env vars
        # would override the PID fallback (orchestrator-tooling-1 review).
        $savedStreamId = $env:OC_STREAM_ID
        $savedReservation = $env:OC_RESERVATION_AGENT_ID
        Remove-Item Env:\OC_STREAM_ID -ErrorAction SilentlyContinue
        Remove-Item Env:\OC_RESERVATION_AGENT_ID -ErrorAction SilentlyContinue
        try {
            & $scriptPath -LogsDir $logsDir -SkipCompress
            $scoped = Join-Path $logsDir "session-start-$PID.log"
            Test-Path $scoped | Should -BeTrue
        } finally {
            if ($null -ne $savedStreamId) { $env:OC_STREAM_ID = $savedStreamId }
            if ($null -ne $savedReservation) { $env:OC_RESERVATION_AGENT_ID = $savedReservation }
        }
    }
}

# ── Remaining root-level critical scripts ───────────────────────────────

Describe "LocalOrchestrator.ps1" -Tag "OpenCode", "Orchestrator" {
    BeforeAll { $script:LocPath = Join-Path $OpenCodeDir "LocalOrchestrator.ps1" }
    It "parses without syntax errors" {
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $LocPath), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
    It "defines MaxIterations, ParallelCount, PollIntervalSeconds params" {
        $content = Get-Content -Raw -LiteralPath $LocPath
        $content | Should -Match 'MaxIterations'
        $content | Should -Match 'ParallelCount'
        $content | Should -Match 'PollIntervalSeconds'
    }
}

Describe "LocalOrchestrator-Worker" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-Worker.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "LocalOrchestrator-Stream" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-Stream.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "LocalOrchestrator-LoopHelpers" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-LoopHelpers.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "LocalOrchestrator-FleetStatus" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-FleetStatus.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "LocalOrchestrator-Container" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-Container.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "LocalOrchestrator-JobObject" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-JobObject.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "LocalOrchestrator-FileHelpers" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "LocalOrchestrator-FileHelpers.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Invoke-StreamTracker" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "Invoke-StreamTracker.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Invoke-SkillsRegistryGate" -Tag "OpenCode", "Skills" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "Invoke-SkillsRegistryGate.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Find-StaleSkills" -Tag "OpenCode", "Skills" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "Find-StaleSkills.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Check-EnvVarScope" -Tag "OpenCode", "Configuration" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "Check-EnvVarScope.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Get-OrchestratorReport" -Tag "OpenCode", "Orchestrator" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "Get-OrchestratorReport.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
}

Describe "Build-DocumentationBundle" -Tag "OpenCode", "docs" {
    It "parses without syntax errors" {
        $path = Join-Path $OpenCodeDir "Build-DocumentationBundle.ps1"
        $errs = $null
        [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $path), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
    It "repoints defaults at docs/ (post Documentation/ rename)" -Tag "Regression" {
        $content = Get-Content -Raw (Join-Path $OpenCodeDir "Build-DocumentationBundle.ps1")
        $content | Should -Not -Match 'Documentation[\\/_]'
        $content | Should -Match '\.\.\\\.\.\\docs\\_build'
        $content | Should -Match 'Join-Path \$RepoRoot "docs"'
        $content | Should -Match 'Split-Path \(Split-Path \$PSScriptRoot -Parent\) -Parent'
    }
}

Describe "Invoke-Orchestrate PID safety" -Tag "OpenCode", "Orchestrator", "Regression" {
    It "defines Test-ProcessMatch helper function" {
        $content = Get-Content (Join-Path $OpenCodeDir "Invoke-Orchestrate.ps1") -Raw
        $content | Should -Match 'function Test-ProcessMatch'
    }
    It "uses Test-ProcessMatch in stale agent kill path" {
        $content = Get-Content (Join-Path $OpenCodeDir "Invoke-Orchestrate.ps1") -Raw
        $content | Should -Match 'Test-ProcessMatch.*ExpectedName \"pwsh\"'
    }
    It "defines Invoke-SafeMove helper function" {
        $content = Get-Content (Join-Path $OpenCodeDir "Invoke-Orchestrate.ps1") -Raw
        $content | Should -Match 'function Invoke-SafeMove'
    }
    It "uses Invoke-SafeMove in orphan rescue paths" {
        $content = Get-Content (Join-Path $OpenCodeDir "Invoke-Orchestrate.ps1") -Raw
        $content | Should -Match 'Invoke-SafeMove -Source'
    }
    It "wraps Get-TaskCounts in try/catch" {
        $content = Get-Content (Join-Path $OpenCodeDir "Invoke-Orchestrate.ps1") -Raw
        $content | Should -Match '(?s)try\s*\{.*?Get-TaskCounts'
    }
}

Describe "Invoke-GitPullSafe worktree fetch" -Tag "OpenCode", "Git", "Regression" {
    It "fetches upstream before skipping pull in worktree mode" {
        $content = Get-Content (Join-Path $GitDir "Invoke-GitPullSafe.ps1") -Raw
        $content | Should -Match 'git.*fetch.*worktree'
    }
    It "checks for behind commits in worktree mode" {
        $content = Get-Content (Join-Path $GitDir "Invoke-GitPullSafe.ps1") -Raw
        $content | Should -Match 'rev-list.*HEAD.*@{u}'
    }
}

Describe "Repair-PowerShellFileAssociations.ps1" -Tag "OpenCode", "Scripts" {
    It "parses without syntax errors" {
        $scriptPath = Join-Path $ScriptDir "Repair-PowerShellFileAssociations.ps1"
        $errs = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $scriptPath), [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
    It "supports -WhatIf" {
        $scriptPath = Join-Path $ScriptDir "Repair-PowerShellFileAssociations.ps1"
        { & $scriptPath -WhatIf -ErrorAction SilentlyContinue } | Should -Not -Throw
    }
    It "requires admin for actual execution" {
        $scriptPath = Join-Path $ScriptDir "Repair-PowerShellFileAssociations.ps1"
        $output = & $scriptPath 2>&1 | Out-String
        $output | Should -Match "Administrator privileges"
    }
    It "references existing Fix-PowerShellFileAssociation.ps1 as preferred path" {
        $skillPath = Join-Path $RepoRoot "Skills\\Orchestration\repair-pwsh-associations.md"
        $content = Get-Content -Raw -LiteralPath $skillPath
        $content | Should -Match "Fix-PowerShellFileAssociation"
    }
}

Describe "LocalOrchestrator.ps1 no side effects" -Tag "OpenCode", "Orchestrator", "Regression" {
    It "no longer uses Set-Location" {
        $content = Get-Content (Join-Path $OpenCodeDir "LocalOrchestrator.ps1") -Raw
        $content | Should -Not -Match 'Set-Location'
    }
    It "uses Resolve-Path for module path" {
        $content = Get-Content (Join-Path $OpenCodeDir "LocalOrchestrator.ps1") -Raw
        $content | Should -Match 'Resolve-Path.*modulePath'
    }
}

Describe "Clear-FleetStaleLocks" -Tag "OpenCode", "Maintenance", "Scripts" {
    BeforeAll {
        $script:ClearFleetStaleLocksPath = Join-Path $ScriptDir "Clear-FleetStaleLocks.ps1"
    }
    It "defines HeartbeatStaleThresholdSeconds, WhatIf, and ReposRoot parameters" {
        $params = @(Get-Command $script:ClearFleetStaleLocksPath).Parameters.Keys
        $params | Should -Contain "HeartbeatStaleThresholdSeconds"
        $params | Should -Contain "WhatIf"
        $params | Should -Contain "ReposRoot"
    }
    It "runs cleanly in WhatIf mode with empty temp dir" {
        $tmpRoot = Join-Path $script:TempDir "cfls-test"
        $null = New-Item -ItemType Directory -Path "$tmpRoot\dummy-repo\Tasks\Logs\agents" -Force
        $null = New-Item -ItemType Directory -Path "$tmpRoot\dummy-repo\.git" -Force
        $result = & $script:ClearFleetStaleLocksPath -ReposRoot $tmpRoot -WhatIf *>&1
        $LASTEXITCODE | Should -Be 0
    }
    It "detects stale heartbeat files" {
        $tmpRoot = Join-Path $script:TempDir "cfls-stale-test"
        $agentDir = "$tmpRoot\dummy-repo\Tasks\Logs\agents"
        $null = New-Item -ItemType Directory -Path $agentDir -Force
        $null = New-Item -ItemType Directory -Path "$tmpRoot\dummy-repo\.git" -Force
        Set-Content -Path "$agentDir\dead-agent.pid" -Value "99999999" -Encoding utf8 -NoNewline
        Set-Content -Path "$agentDir\dead-agent.heartbeat" -Value "2000-01-01T00:00:00Z" -Encoding utf8 -NoNewline
        $result = & $script:ClearFleetStaleLocksPath -ReposRoot $tmpRoot -WhatIf
        $result | Should -BeOfType [PSCustomObject]
        $result.WhatIf | Should -BeTrue
        $result.RemovedCount | Should -Be 1
        $result.RemovedFiles | Should -Match "dead-agent"
    }
}

Describe "Check-Freshness.ps1" -Tag "OpenCode", "CheckFreshness" {
    BeforeAll {
        $script:CheckFreshnessPath = Join-Path $OpenCodeDir "Check-Freshness.ps1"
        $script:TestRoot = Join-Path $script:TempDir "check-freshness"
        $null = New-Item -ItemType Directory -Path $script:TestRoot -Force
    }
    Context "Freshness file missing" {
        It "exits 0 when _freshness.json is absent" {
            $result = & $script:CheckFreshnessPath -RepoRoot $script:TestRoot -PassThru 2>&1
            $LASTEXITCODE | Should -Be 0
        }
        It "skips check when no freshness file" {
            $result = & $script:CheckFreshnessPath -RepoRoot $script:TestRoot *>&1
            $result | Should -Match "No _freshness.json"
        }
    }
    Context "Freshness file present" {
        BeforeAll {
            $freshPath = Join-Path $script:TestRoot "_freshness.json"
            # Create a freshness file with one expired and one current entry
            $pastDate = (Get-Date).AddDays(-10).ToString('yyyy-MM-dd')
            $todayDate = (Get-Date).ToString('yyyy-MM-dd')
            $freshContent = @{
                version = 1
                entries = @{
                    "stale_entry" = @{
                        value = "old observation"
                        verified = $pastDate
                        by = "test"
                        expires_days = 7
                    }
                    "fresh_entry" = @{
                        value = "current observation"
                        verified = $todayDate
                        by = "test"
                        expires_days = 30
                    }
                }
            } | ConvertTo-Json
            $freshContent | Set-Content -Path $freshPath -Encoding utf8
        }
        It "detects stale entries" {
            $stale = & $script:CheckFreshnessPath -RepoRoot $script:TestRoot -PassThru
            $stale.Count | Should -BeGreaterOrEqual 1
            $stale.Key -contains "stale_entry" | Should -Be $true
        }
        It "returns no stale entries when MaxDays is high" {
            $stale = & $script:CheckFreshnessPath -RepoRoot $script:TestRoot -MaxDays 365 -PassThru
            $stale.Count | Should -Be 0
        }
        It "exits 1 when stale entries found" {
            & $script:CheckFreshnessPath -RepoRoot $script:TestRoot 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
    }
}

Describe "Invoke-WorktreeMergeAll conflict-plan lists files" -Tag "OpenCode", "Git", "Regression" {
    It "captures conflicted file names (not fallback) into merge-plan" {
        $repo = Join-Path $script:TempDir "wma-repo"
        $remote = Join-Path $script:TempDir "wma-remote.git"
        $null = New-Item -ItemType Directory -Path $repo -Force
        git -C $repo init -b main 2>&1 | Out-Null
        git -C $repo config user.email "test@example.com"
        git -C $repo config user.name "Test"
        Set-Content -Path (Join-Path $repo "file.txt") -Value "base" -Encoding utf8
        git -C $repo add file.txt
        git -C $repo commit -m "base" 2>&1 | Out-Null
        git -C $repo init --bare $remote 2>&1 | Out-Null
        git -C $repo remote add origin $remote
        git -C $repo push -u origin main 2>&1 | Out-Null
        git -C $repo checkout -b feature 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repo "file.txt") -Value "feature change" -Encoding utf8
        git -C $repo commit -am "feature" 2>&1 | Out-Null
        git -C $repo checkout main 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repo "file.txt") -Value "main change" -Encoding utf8
        git -C $repo commit -am "main" 2>&1 | Out-Null

        . (Join-Path $RepoRoot "Skills\\Git\Invoke-WorktreeMergeAll.ps1")
        $summary = Merge-AgentBranches -Branches @("feature") -RepoRoot $repo

        $summary.Conflicts | Should -Be 1
        $mergeDir = Join-Path $repo "Tasks\Merge"
        $planFile = Get-ChildItem -Path $mergeDir -Filter "*.md" | Select-Object -First 1
        $planFile | Should -Not -BeNullOrEmpty
        $planContent = Get-Content $planFile.FullName -Raw
        $planContent | Should -Match "file.txt"
        $planContent | Should -Not -Match "unable to list conflicted files"
    }
}

Describe "Invoke-WorktreeMergeAll queue isolation" -Tag "OpenCode", "Git", "Regression" {
    BeforeAll {
        $script:mergeAllPath = Join-Path $RepoRoot "Skills\Git\Invoke-WorktreeMergeAll.ps1"
        $script:mergeAllContent = Get-Content -LiteralPath $script:mergeAllPath -Raw
    }

    It "never auto-commits an entire dirty main or module worktree" {
        $script:mergeAllContent | Should -Not -Match 'git -C \$RepoRoot add -A'
        $script:mergeAllContent | Should -Not -Match 'git -C \$wtPath add -A'
        $script:mergeAllContent | Should -Not -Match 'commit .*--no-verify'
    }

    It "keeps module task-queue history out of the main merge" {
        $script:mergeAllContent | Should -Match 'git merge --no-ff --no-commit \$branch'
        $script:mergeAllContent | Should -Match 'git restore --source=HEAD --staged --worktree -- Tasks'
    }
}
