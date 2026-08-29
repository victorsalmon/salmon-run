# 4C dossier: pond-engine empty-lane crash

**Repo:** salmon-run - main   **Started:** 2026-08-28

## Concern

The Salmon Run unattended supervisor (`Run-SalmonRun.ps1`) repeatedly reported:

```text
[ERROR] pond engine exited with code 1 (consecutive crashes: 1)
[ERROR] pond engine exited with code 1 (consecutive crashes: 2)
```

The pond engine process exited within minutes of starting. `Run-SalmonRun` did not
capture the child `Start-SalmonRun` stdout or stderr, so the actual exception
was hidden and only the exit code was visible.

## Cause

`Modules/SalmonRun.PondEngine/Public/Start-PondEngine.ps1` function
`Invoke-PondReapLane` builds a `PondGroup` for a finished lane and then assigns
a namespace for that group:

```powershell
if ($files.Count -gt 0 -and $files[0].Name -match '^\d{4}[-.]?\d{2}[-.]?\d{2}[-.]([^-]+)') {
    $reapGroup.Namespace = $Matches[1]
} else {
    $reapGroup.Namespace = $files[0].BaseName
}
```

When a `Working/` lane directory has sentinel files (`.complete`, `.failed`,
`.run`) but no `.md` plan file, `$files.Count` is `0`. The `else` branch still
tries to read `$files[0].BaseName`, which throws `Index was outside the bounds of
the array`. Because the exception was not caught inside `Start-PondEngine`, the
entire engine process terminated with exit code `1`.

The `else` branch was itself a sibling of the same anti-pattern: several places
read `$files[0]` with a count guard, but this particular branch did not.

## Countermeasure

1. Guard the empty-lane case in `Invoke-PondReapLane`:
   ```powershell
   if ($files.Count -gt 0 -and $files[0].Name -match '^\d{4}[-.]?\d{2}[-.]?\d{2}[-.]([^-]+)') {
       $reapGroup.Namespace = $Matches[1]
   } elseif ($files.Count -gt 0) {
       $reapGroup.Namespace = $files[0].BaseName
   } else {
       $reapGroup.Namespace = $Lane.Id
   }
   ```

2. Improve crash diagnosis by redirecting the child `Start-SalmonRun` process
   stdout and stderr in `Run-SalmonRun.ps1` to
   `~/.salmon/Logs/orchestrator-child.{log,err}` so future engine crashes leave
   a complete stack trace.

## Check

- `Tests/SalmonRun.PondEngine.Tests.ps1` passes: 53/0/0/0.
- Full `PondEngine` reproduction suite
  (`ProjectPlanning`, `ReviewVerdict`, `ProjectLifecycle`, `PondScheduling`,
  `PondEngine`) passes: 66/0/0/0.
- The actual failing stack trace was observed in the `Run-SalmonRun` console
  output before the fix:
  ```text
  Start-PondEngine: C:\Repos\Public\salmon-run\Start-SalmonRun.ps1:145
  Index was outside the bounds of the array.
  ```
- The orchestrator is being restarted after the fix and re-monitored for the
  remaining hour.
