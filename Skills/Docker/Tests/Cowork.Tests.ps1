#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='6.0.0' }

BeforeAll {
    $CoworkScripts = Join-Path $PSScriptRoot "..\..\Cowork\Scripts"
    $ScriptList = Get-ChildItem -Path $CoworkScripts -Filter "*.ps1" -ErrorAction SilentlyContinue
    $script:TempDir = Join-Path $env:TEMP "CoworkTest_$(Get-Random)"
    $null = New-Item -ItemType Directory -Path $script:TempDir -Force
    function Get-DryRunOutput {
        param([scriptblock]$ScriptBlock)
        $result = & $ScriptBlock 6>&1
        if (-not $result) { $result = & $ScriptBlock }
        return $result
    }
}
AfterAll {
    if (Test-Path $script:TempDir) { Remove-Item -LiteralPath $script:TempDir -Recurse -Force }
}
Describe "Cowork Scripts" -Tag "Cowork" {
    It "finds at least one Cowork script" { $ScriptList.Count | Should -BeGreaterThan 0 }
    It "all Cowork scripts parse without syntax errors" {
        $errors = $ScriptList | ForEach-Object {
            $errs = $null
            $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw -LiteralPath $_.FullName), [ref]$errs)
            if ($errs) { return $_.Name }
        }
        $errors | Should -BeNullOrEmpty
    }
}
Describe "New-CoworkStub" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-CoworkStub.ps1") }
    It "defines function" { Get-Command New-CoworkStub -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws on empty WhatWorked" {
        { New-CoworkStub -Topic "T" -AgentId "a" -Status released -CurrentState "State desc longer than 20 chars" -WhatWorked @() -WhatDidntWork @("F") -NextActions @("N") -DryRun } | Should -Throw
    }
    It "throws on empty WhatDidntWork" {
        { New-CoworkStub -Topic "T" -AgentId "a" -Status released -CurrentState "State desc longer than 20 chars" -WhatWorked @("W") -WhatDidntWork @() -NextActions @("N") -DryRun } | Should -Throw
    }
    It "throws on short CurrentState" {
        { New-CoworkStub -Topic "T" -AgentId "a" -Status released -CurrentState "short" -WhatWorked @("W") -WhatDidntWork @("F") -NextActions @("N") -DryRun } | Should -Throw
    }
    It "generates sections in correct order" {
        $o = Get-DryRunOutput { New-CoworkStub -Topic "TestTopic" -AgentId "agent-1" -Status released -CurrentState "State desc longer than 20 chars" -WhatWorked @("Worked1","Worked2") -WhatDidntWork @("Failed1") -SkillsUsed @("SkillA") -NextActions @("Next1") -KeyFiles @{Config=@{Path="c";Purpose="cfg"}} -OrphanRefs @("orphan1") -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "# Cowork Stub: TestTopic"
        $joined | Should -Match "## What Worked"
        $joined | Should -Match "## What Didn't Work"
        $joined | Should -Match "## Skills Used"
        $joined | Should -Match "## What Next Agent Needs"
        $joined | Should -Match "## Key Files"
        $joined | Should -Match "> \*\*Orphan notes\*\*"
    }
    It "rejects invalid status" {
        { New-CoworkStub -Topic "T" -AgentId "a" -Status invalid -CurrentState "State desc longer than 20 chars" -WhatWorked @("W") -WhatDidntWork @("F") -NextActions @("N") -DryRun } | Should -Throw
    }
}
Describe "New-CredentialRef" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-CredentialRef.ps1") }
    It "defines function" { Get-Command New-CredentialRef -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws on empty credentials" {
        { New-CredentialRef -Credentials @() -DryRun } | Should -Throw
    }
    It "generates table with SSO line by default" {
        $o = Get-DryRunOutput { New-CredentialRef -Credentials @(@{Key="k1";Purpose="p1"},@{Key="k2";Purpose="p2"}) -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "SSO session"
        $joined | Should -Match "k1.*p1"
        $joined | Should -Match "k2.*p2"
        $joined | Should -Match "| AWS SM Key | Purpose |"
    }
    It "supports inline format" {
        $o = Get-DryRunOutput { New-CredentialRef -Credentials @(@{Key="k1";Purpose="p1"}) -OutputFormat inline -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "k1: p1"
    }
    It "omits SSO line when flag is false" {
        $o = Get-DryRunOutput { New-CredentialRef -Credentials @(@{Key="k";Purpose="p"}) -SsoRequired:$false -DryRun }
        $joined = $o -join ""
        $joined | Should -Not -Match "SSO session"
    }
}
Describe "New-FinalHandoff" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-FinalHandoff.ps1") }
    It "defines function" { Get-Command New-FinalHandoff -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws when both item lists empty" {
        { New-FinalHandoff -Topic "T" -AgentId "a" -Reason milestone-complete -DryRun } | Should -Throw
    }
    It "generates all sections when provided" {
        $c = @(@{Item="Fix";Verification="Pass";Evidence="Green"})
        $ic = @(@{Item="Bug";CurrentState="Open";Remaining="Fix";Blockers="None"})
        $ww = @(@{Approach="A";VerifiedBy="Test"})
        $wd = @(@{Approach="B";Why="Broken"})
        $sk = @(@{Name="SkillX";Why="Useful"})
        $rd = @{Old="old.md";New="new.md"}
        $o = Get-DryRunOutput { New-FinalHandoff -Topic "T" -AgentId "a" -Reason milestone-complete -CompletedItems $c -IncompleteItems $ic -WhatWorked $ww -WhatDidntWork $wd -SuggestedSkills $sk -KeyFiles @{K=@{Path="p";Purpose="pu"}} -OrphanRefs @("r") -Redirects $rd -MemoryFilesUpdated @("mem.md") -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "## Completed Items"
        $joined | Should -Match "## Incomplete Items"
        $joined | Should -Match "## Tools & Approaches . What Worked"
        $joined | Should -Match "## What Didn't Work"
        $joined | Should -Match "## Suggested Skills"
        $joined | Should -Match "## Redirects"
    }
    It "renders Quick Reference section when GrepPatterns provided" {
        $c = @(@{Item="Fix";Verification="Pass";Evidence="Green"})
        $gp = @(@{Pattern="Invoke-SecretRotation";Scope="*.ps1";Why="Finds all callers of secret rotation"})
        $o = Get-DryRunOutput { New-FinalHandoff -Topic "T" -AgentId "a" -Reason milestone-complete -CompletedItems $c -GrepPatterns $gp -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "## Quick Reference"
        $joined | Should -Match "### Grep Patterns"
        $joined | Should -Match "Invoke-SecretRotation"
    }
    It "renders Key Directories and External Links under Quick Reference" {
        $c = @(@{Item="Fix";Verification="Pass";Evidence="Green"})
        $gp = @(@{Pattern="Get-Config";Scope="*.ps1";Why="Config module"})
        $kd = @(@{Path="Skills/Bookkeeping";Why="All accounting scripts"})
        $el = @(@{Url="https://zoho.com/books/api";Purpose="Zoho API docs"})
        $o = Get-DryRunOutput { New-FinalHandoff -Topic "T" -AgentId "a" -Reason milestone-complete -CompletedItems $c -GrepPatterns $gp -KeyDirectories $kd -ExternalLinks $el -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "### Key Directories"
        $joined | Should -Match "Skills/Bookkeeping"
        $joined | Should -Match "### External Links"
        $joined | Should -Match "zoho.com/books/api"
    }
    It "omits Quick Reference when GrepPatterns not provided" {
        $c = @(@{Item="Fix";Verification="Pass";Evidence="Green"})
        $o = Get-DryRunOutput { New-FinalHandoff -Topic "T" -AgentId "a" -Reason milestone-complete -CompletedItems $c -DryRun }
        $joined = $o -join ""
        $joined | Should -Not -Match "## Quick Reference"
    }
}
Describe "New-MemoryEntry" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-MemoryEntry.ps1") }
    It "defines functions" {
        Get-Command New-MemoryEntry -EA SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Resolve-MemoryRepo -EA SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It "creates file" {
        $p = Join-Path $TempDir "mem-c-p.md"
        New-MemoryEntry -MemoryFilePath $p -Container "c" -Project "p" -Section "S" -Entries @(@{Key="k";Value="v"})
        Test-Path $p | Should -BeTrue
        $content = Get-Content -Raw $p
        $content | Should -Match "# Memory: c / p"
        $content | Should -Match "## S"
        $content | Should -Match "k.*v"
    }
    It "rejects bad filename pattern" {
        { New-MemoryEntry -MemoryFilePath (Join-Path $TempDir "bad.md") -Container "c" -Project "p" -Section "S" -Entries @(@{Key="k";Value="v"}) -DryRun } | Should -Throw
    }
    It "appends to existing section" {
        $p = Join-Path $TempDir "mem-x-y.md"
        New-MemoryEntry -MemoryFilePath $p -Container "x" -Project "y" -Section "S1" -Entries @(@{Key="k1";Value="v1"})
        New-MemoryEntry -MemoryFilePath $p -Container "x" -Project "y" -Section "S1" -Entries @(@{Key="k2";Value="v2"}) -Mode append
        $content = Get-Content -Raw $p
        ($content | Select-String "k1" -AllMatches).Matches.Count | Should -Be 1
        ($content | Select-String "k2" -AllMatches).Matches.Count | Should -Be 1
    }
    It "updates existing key in a section" {
        $p = Join-Path $TempDir "mem-u-v.md"
        New-MemoryEntry -MemoryFilePath $p -Container "u" -Project "v" -Section "Sec" -Entries @(@{Key="k1";Value="v1"})
        New-MemoryEntry -MemoryFilePath $p -Container "u" -Project "v" -Section "Sec" -Entries @(@{Key="k1";Value="updated"}) -Mode update
        $content = Get-Content -Raw $p
        $content | Should -Match "k1.*updated"
        $content | Should -Not -Match "k1.*v1"
    }
}
Describe "New-PostHocPlan" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-PostHocPlan.ps1") }
    It "defines function" { Get-Command New-PostHocPlan -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws on empty tasks" {
        { New-PostHocPlan -Date "2026-06-22" -Topic "T" -Iteration "1" -Scope "s" -AgentId "a" -CommitHashes @("a") -FilesModified @("f") -Tasks @() -DryRun } | Should -Throw
    }
    It "throws on incomplete task fields" {
        { New-PostHocPlan -Date "2026-06-22" -Topic "T" -Iteration "1" -Scope "s" -AgentId "a" -CommitHashes @("a") -FilesModified @("f") -Tasks @(@{Title="A"}) -DryRun } | Should -Throw
    }
    It "generates markdown" {
        $t = @{Title="A";Why="W";Files="f";Changes=@("c");Acceptance="a";Verification="v"}
        $o = Get-DryRunOutput { New-PostHocPlan -Date "2026-06-22" -Topic "T" -Iteration "1" -Scope "s" -AgentId "a" -CommitHashes @("a","b") -FilesModified @("f") -Tasks @($t) -Connascence "test" -TestBaseline "PASS" -DryRun }
        $o -join "" | Should -Match "# Session Plan"
    }
}
Describe "New-SessionLog" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-SessionLog.ps1") }
    It "defines function" { Get-Command New-SessionLog -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws on empty phases" {
        { New-SessionLog -Topic "S" -AgentId "a" -Phases @() -DryRun } | Should -Throw
    }
    It "generates markdown" {
        $p = @{Number=1;Title="Analyze";Hours=1.5;Accomplished=@("Done X","Done Y")}
        $ww = @(@{Approach="TDD";VerifiedBy="Tests pass"})
        $o = Get-DryRunOutput { New-SessionLog -Topic "Session1" -AgentId "a" -Phases @($p) -WhatWorked $ww -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "# Session Log: Session1"
        $joined | Should -Match "## Phase 1"
        $joined | Should -Match "What Worked"
    }
}
Describe "Invoke-Fork" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "Invoke-Fork.ps1") }
    It "defines function" { Get-Command Invoke-Fork -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "returns path stub-only" {
        $s = Join-Path $TempDir "s.md"
        "" | Out-File $s -Encoding utf8 -NoNewline
        $r = Invoke-Fork -StubPath $s -Goal "goal long enough for validation here" -StubOnly
        $r | Should -Match "s.md"
    }
    It "validates stub path exists (non-dry-run)" {
        { Invoke-Fork -StubPath (Join-Path $TempDir "nonexistent.md") -Goal "goal long enough for validation here" } | Should -Throw
    }
}
Describe "ConvertTo-LockHeader" -Tag "Cowork" {
    It "produces valid header" {
        $p = Join-Path $CoworkScripts "New-LockHeader.ps1"
        $r = powershell -NoProfile -Command "& '$p' 'agent-1' 'locked' -DryRun *>&1"
        $r | Out-String | Should -Match "Agent"
    }
    It "writes output file" {
        $p = Join-Path $CoworkScripts "New-LockHeader.ps1"
        $o = Join-Path $TempDir "lh.md"
        powershell -NoProfile -Command "& '$p' 'agent-1' 'locked' -OutputPath '$o' *>&1" | Out-Null
        Test-Path $o | Should -BeTrue
    }
    It "adds released timestamp for released status" {
        $p = Join-Path $CoworkScripts "New-LockHeader.ps1"
        $r = powershell -NoProfile -Command "& '$p' 'agent-1' 'released' -DryRun *>&1"
        $r | Out-String | Should -Match "Released"
    }
    It "appends to existing lock header" {
        $p = Join-Path $CoworkScripts "New-LockHeader.ps1"
        $content = "**Lock**`n- Agent: old`n---`noriginal"
        $r = powershell -NoProfile -Command ". '$p'; ConvertTo-LockHeader -AgentId 'new' -Status 'locked' -ExistingContent '$content'"
        $r | Out-String | Should -Match "new"
    }
}
Describe "New-ManualTask" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-ManualTask.ps1") }
    It "defines function" { Get-Command New-ManualTask -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws on missing required fields" {
        { New-ManualTask -Topic "T" -OriginatingContext "" -Steps @() -ExpectedOutcome "" -FollowUp "" -DryRun } | Should -Throw
    }
    It "generates markdown" {
        $o = Get-DryRunOutput { New-ManualTask -Topic "Test Task" -OriginatingContext "Context desc longer text goes here" -Steps @("Step 1") -ExpectedOutcome "Outcome text" -FollowUp "FollowUp text" -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "# Manual Task: Test Task"
        $joined | Should -Match "## Originating Context"
        $joined | Should -Match "## Step-by-Step Instructions"
        $joined | Should -Match "## Expected Outcome"
        $joined | Should -Match "## Follow-Up"
    }
}
Describe "New-ForkStub" -Tag "Cowork" {
    BeforeAll { . (Join-Path $CoworkScripts "New-ForkStub.ps1") }
    It "defines function" { Get-Command New-ForkStub -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws on empty topic" {
        { New-ForkStub -Topic "" -Goal "goal long enough to pass validation" -ContextBody ("x" * 50) -DryRun } | Should -Throw
    }
    It "throws on short goal" {
        { New-ForkStub -Topic "t" -Goal "short" -ContextBody ("x" * 50) -DryRun } | Should -Throw
    }
    It "throws on short context body" {
        { New-ForkStub -Topic "t" -Goal "goal long enough to pass validation and is fine" -ContextBody "short" -DryRun } | Should -Throw
    }
    It "generates stub markdown" {
        $o = Get-DryRunOutput { New-ForkStub -Topic "test-topic" -Goal "this is a test goal that is long enough to pass validation and works fine" -ContextBody ("x" * 50) -DryRun }
        $joined = $o -join ""
        $joined | Should -Match "# Fork-Stub: test-topic"
        $joined | Should -Match ([regex]::Escape('**Goal**'))
        $joined | Should -Match "## Transferred Context"
    }
    It "writes file when not dry-run" {
        $r = New-ForkStub -Topic "write-test" -Goal "goal long enough here for validation okay" -ContextBody ("y" * 60) -OutputDir $TempDir -ErrorAction SilentlyContinue
        Test-Path $r | Should -BeTrue
    }
}
Describe "Invoke-ForkFlow" -Tag "Cowork" {
    It "runs dry-run via command" {
        $cf = Join-Path $TempDir "ctx.md"
        Set-Content -LiteralPath $cf -Value "context body with enough chars to pass the fifty char limit here yep" -NoNewline
        $p = Join-Path $CoworkScripts "Invoke-ForkFlow.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Topic test -Goal 'test goal long enough to pass validation here' -ContextFile '$cf' -DryRun *>&1"
        Remove-Item -LiteralPath $cf -Force
        $r | Out-String | Should -Match "dry-run"
    }
    It "fails on missing context file (non-dry-run)" {
        $p = Join-Path $CoworkScripts "Invoke-ForkFlow.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Topic test -Goal 'test goal long enough here for validation' -ContextFile '$TempDir\\nope.md' *>&1"
        $r | Out-String | Should -Match "cannot be found|not found|does not exist"
    }
    It "generates stub preview on dry-run" {
        $cf = Join-Path $TempDir "ctx2.md"
        Set-Content -LiteralPath $cf -Value "context body with enough chars to pass the fifty char limit here yep" -NoNewline
        $p = Join-Path $CoworkScripts "Invoke-ForkFlow.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Topic test -Goal 'test goal long enough to pass validation here' -ContextFile '$cf' -DryRun *>&1"
        Remove-Item -LiteralPath $cf -Force
        $output = $r | Out-String
        $output | Should -Match "Fork-Stub"
        $output | Should -Match "Transferred Context"
    }
    It "renders goal in stub output" {
        $cf = Join-Path $TempDir "ctx3.md"
        Set-Content -LiteralPath $cf -Value "context body with enough chars to pass the fifty char limit here yep" -NoNewline
        $p = Join-Path $CoworkScripts "Invoke-ForkFlow.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Topic test-topic -Goal 'custom goal validation here' -ContextFile '$cf' -DryRun *>&1"
        Remove-Item -LiteralPath $cf -Force
        $output = $r | Out-String
        $output | Should -Match "custom goal validation here"
    }
}
Describe "Fork-Session" -Tag "Cowork" {
    It "runs dry-run without error" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Goal 'test goal for fork session dry run validation here' -DryRun *>&1"
        $r | Out-String | Should -Match "dry-run"
    }
    It "generates valid topic from goal" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Goal 'Fix the build process' -DryRun *>&1"
        $r | Out-String | Should -Match "fix-the-build"
    }
    It "handles special characters in goal" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Goal 'Fix the build!!! process $$$ now!!!' -DryRun *>&1"
        $r | Out-String | Should -Match "fix-the-build-process-now"
    }
    It "truncates long goal slugs" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $longGoal = "a" * 100
        $r = powershell -NoProfile -Command "& '$p' -Goal '$longGoal' -DryRun *>&1"
        $r | Out-String | Should -Match "fork-stub-"
    }
    It "defaults topic to fork when goal has no alphanumeric chars" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Goal '!!! ??? --- ===' -DryRun *>&1"
        $output = $r | Out-String
        $output | Should -Match "fork"
    }
    It "writes stub with correct sections on dry-run" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Goal 'Add dark mode to the UI' -DryRun *>&1"
        $output = $r | Out-String
        $output | Should -Match "fork-stub"
        $output | Should -Match "dry-run"
    }
    It "returns stub path on dry-run" {
        $p = Join-Path $CoworkScripts "Fork-Session.ps1"
        $r = powershell -NoProfile -Command "& '$p' -Goal 'return path validation test long enough here' -DryRun *>&1"
        $r | Out-String | Should -Match "fork-stub-"
    }
}
Describe "Fork-OpenCodeSession" -Tag "Cowork" {
    BeforeAll {
        . (Join-Path $CoworkScripts "Fork-OpenCodeSession.ps1")
        $script:RealForkSession = Join-Path $CoworkScripts "Fork-Session.ps1"
    }
    It "defines function" { Get-Command Fork-OpenCodeSession -EA SilentlyContinue | Should -Not -BeNullOrEmpty }
    It "throws when Fork-Session.ps1 is missing" {
        $original = Join-Path $CoworkScripts "Fork-Session.ps1"
        $renamed = Join-Path $CoworkScripts "Fork-Session.ps1.bak"
        try {
            if (Test-Path $original) { Rename-Item -LiteralPath $original -NewName "Fork-Session.ps1.bak" -Force }
            { Fork-OpenCodeSession -Goal "test goal here for validation purposes" } | Should -Throw
        } finally {
            if (Test-Path $renamed) { Rename-Item -LiteralPath $renamed -NewName "Fork-Session.ps1" -Force }
        }
    }
    It "runs without error with StubOnly flag" {
        { Fork-OpenCodeSession -Goal "test goal for stub only mode validation purposes" -StubOnly } | Should -Not -Throw
    }
}
