# opencode-windows-posix-tools - 4C Bug Fix

**Repo:** salmon-run - main   **Started:** 2026-08-28

## Concern

OpenCode agents executing on Windows through the `Opencode.ps1` executor emit POSIX shell commands (`head`, `grep`, `find`, `cat`, `ls -d`, etc.). These are not available in the default Windows `pwsh`/`cmd` environment, so the child shell fails with `The term '<command>' is not recognized as a name of a cmdlet, function, script file, or executable program`. The lane aborts, writes `.failed`, and never completes the plan.

Repro test: `Tests/SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1` context `Windows POSIX tool availability`.

## Cause

The `Invoke-OpencodeProvider` function launches the `opencode` CLI via `Start-Process` with the current process environment. On Windows the inherited `PATH` places `C:\Windows\System32` (which provides a Windows `find.exe`) and `pwsh` built-in aliases (`ls`) before any POSIX tools. The executor makes no attempt to add Git for Windows `\usr\bin` to the child `PATH`, so the agent's POSIX commands cannot resolve.

Sibling occurrences:
- `Modules/SalmonRun.PondEngine/Executors/Opencode.ps1` - the only external-provider executor that directly spawns a model CLI on Windows. Other executors (`Dsh.ps1`, `Codex.ps1`, `Devin.ps1`) launch their own CLIs but do not need POSIX shell tools because they either use `dsh`/`codex`/`devin` native commands or the local executor.

## Countermeasure

*Pending - add `Resolve-OpencodeWindowsToolPath` helper and prepend Git for Windows `\usr\bin` and `\bin` to the child `PATH` before `Start-Process`.*

## Check

*Pending - red-to-green test run, full Pester suite, mutation analysis.*
