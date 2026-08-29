# 4C — Full-suite `PondEngine` failures under module reload

## Concern

The full Pester portfolio failed with 12 cross-test side-effects.  All failing
`PondEngine`/`OrchestratorE2E`/`PondScheduling` tests passed when run in
isolation, so the failures were harness contamination, not production bugs.

```text
MethodException: Cannot find an overload for "Add" and the argument count: "1".
at Select-PondGroups, ...\Select-PondGroups.ps1:55
at Start-PondEngine, ...\Start-PondEngine.ps1:273
```

## Cause

`SalmonRun.Installer.Tests.ps1` imports the `SalmonRun.PondEngine` module and
leaves a `PondGroup` type in the session.  Later tests (`PondEngine.Tests.ps1`,
`PondScheduling`, `OrchestratorE2E`) remove and re-import the module.  In that
state, `Select-PondGroups` created a generic
`List<PondGroup>` and then tried to add a `PondGroup` object that the runtime
saw as a different type identity, so the `Add` overload could not be resolved.

The minimal repro is:

```powershell
Invoke-Pester -Path 'Tests/SalmonRun.Installer.Tests.ps1','Tests/SalmonRun.PondEngine.Tests.ps1'
```

## Countermeasure

In `Modules/SalmonRun.PondEngine/Private/Select-PondGroups.ps1`:

- Replace `List<PondGroup>` with `System.Collections.ArrayList`.
- Suppress the `ArrayList.Add` return value (`$null =`) because `Add` returns
  the integer index and would otherwise pollute the function output.

This removes the generic `PondGroup` type-coupling inside `Select-PondGroups`
and makes the scheduler tolerant of stale `PondGroup` definitions in the
session.

## Check

- `Invoke-Pester -Path 'Tests/SalmonRun.Installer.Tests.ps1','Tests/SalmonRun.PondEngine.Tests.ps1'`
  passes (58 tests, 0 failures).
- The affected wider subset
  (`Installer`, `PondEngine`, `PondScheduling`, `OrchestratorE2E`, `ProjectLifecycle`)
  passes (65 tests, 0 failures).
- Full portfolio re-run: **640 passed, 0 failed, 8 skipped**.
