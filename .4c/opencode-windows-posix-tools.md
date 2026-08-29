# opencode-windows-posix-tools - 4C Bug Fix

**Repo:** salmon-run - main   **Started:** 2026-08-28

## Concern

OpenCode agents executing on Windows through the `Opencode.ps1` executor emit POSIX shell commands (`head`, `grep`, `find`, `cat`, `ls -d`, etc.). These are not available in the default Windows `pwsh`/`cmd` environment, so the child shell fails with `The term '<command>' is not recognized as a name of a cmdlet, function, script file, or executable program`. The lane aborts, writes `.failed`, and never completes the plan.

Repro test: `Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1` context `Windows POSIX tool availability`.

Repro run output (failing):

```text
[-] Resolve-OpencodeWindowsToolPath finds Git for Windows POSIX tools on Windows
    CommandNotFoundException: The term 'Resolve-OpencodeWindowsToolPath' is not recognized ...
[-] Invoke-OpencodeProvider prepends POSIX tools to the child PATH on Windows
    Expected regular expression 'Git\usr\bin' to match 'C:\Program Files\PowerShell\7;...'
```

## Cause

The `Invoke-OpencodeProvider` function launches the `opencode` CLI via `Start-Process` with the current process environment. On Windows the inherited `PATH` places `C:\Windows\System32` (which provides a Windows `find.exe`) and `pwsh` built-in aliases (`ls`) before any POSIX tools. The executor makes no attempt to add Git for Windows `\usr\bin` to the child `PATH`, so the agent's POSIX commands cannot resolve.

Sibling occurrences:
- `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1` - the only external-provider executor that directly spawns a model CLI on Windows. Other executors (`Dsh.ps1`, `Codex.ps1`, `Devin.ps1`) launch their own CLIs but do not need POSIX shell tools because they either use `dsh`/`codex`/`devin` native commands or the local executor.

## Countermeasure

Add `Resolve-OpencodeWindowsToolPath` helper that locates Git for Windows and, in `Invoke-OpencodeProvider`, prepends `\usr\bin` and `\bin` to the child process `PATH` before `Start-Process`. This makes `head`, `grep`, `find`, `cat`, etc. resolvable without modifying the prompt or weakening the agent's freedom to use POSIX pipelines.

Changed: `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1`.

## Check

Repro test now:

```text
[+] Resolve-OpencodeWindowsToolPath finds Git for Windows POSIX tools on Windows
[+] Invoke-OpencodeProvider prepends POSIX tools to the child PATH on Windows
[+] live OpenCode plan runs to .complete
Tests Passed: 12, Failed: 0, Skipped: 0
```

Targeted Pester run (OpenCode contract):

```text
Invoke-Pester -Path Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1
Tests Passed: 12, Failed: 0, Skipped: 0
```

Full configured QA contract:

```text
Invoke-Pester -Path Tests
Tests Passed: 627, Failed: 11, Skipped: 8
```

The 11 remaining failures are pre-existing and unrelated to OpenCode:
- `Tests/SalmonRun.PondEngine.Tests.ps1` - one functional-recovery E2E test (`moves a Code plan to Complete using the Local harness`) still expects project-bundle completion.
- `Tests/SalmonRun.DeployState.Tests.ps1` - 4 tests fail because `Get-SalmonTaskRoot` is not loaded; module `RequiredModules` resolution issue.
- `Tests/SalmonRun.Config.Tests.ps1` - 11 tests fail because `SalmonRun.Config` requires `SalmonRun.Core` which is not loaded by the test bootstrap.

Property/mutation proof: Not applicable to this environmental PATH-only change. The contract test includes a live integration check and a mock-based PATH assertion.

Red-gate proof:
- Test commit: `5eafee6 test: failing repro for OpenCode Windows POSIX tool PATH`
- Fix commit: `33f3b59 fix: prepend Git for Windows POSIX tools to OpenCode PATH on Windows`
- The test was run before the fix and failed (see Concern section); the same test run after the fix passed with the live OpenCode integration.
