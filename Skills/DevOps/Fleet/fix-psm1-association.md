# Fix PowerShell File Association (.psm1 / .ps1) — opencode skill

**Type**: utility
**Flavor**: opencode
**Registered in**: skills.json → "opencode/fix-psm1-association"

## Purpose

Diagnose and fix the recurring "PowerShell module (.psm1) opens in IDE instead of running" issue on Windows hosts. The root cause is missing `shell\open\command` registry entries for the proper PowerShell module ProgIDs, combined with an IDE (typically VS Code forks like Antigravity, Cursor, or Trae) that has aggressively registered its own ProgIDs in `HKCU:\SOFTWARE\Classes\`.

## Trigger

- User says "fix .psm1 association" / "Antigravity pops up for psm1" / "psm1 opens in IDE"
- User sees "Pick an app" dialogs for `.psm1` files when running Orchestrate/Redeploy
- A script's `Invoke-Item` / `Start-Process` on a `.psm1` file launches an IDE

## Symptoms

- `cmd /c assoc .psm1` returns "File association not found"
- `HKCU:\SOFTWARE\Classes\Microsoft.PowerShellModule.1\shell\open\command` does not exist
- `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psm1\OpenWithList` contains `Antigravity.exe` or similar IDE entries
- Hundreds of custom `Antigravity.*` / `AntigravityIDE.*` ProgIDs in `HKCU:\SOFTWARE\Classes\`

## Diagnosis Procedure

Run these in PowerShell to confirm the problem:

```powershell
# 1. Check if the proper ProgIDs have a command
$paths = @(
    "HKCU:\SOFTWARE\Classes\Microsoft.PowerShellModule.1\shell\open\command",
    "HKCU:\SOFTWARE\Classes\PowershellModuleScript\shell\open\command"
)
$paths | ForEach-Object { 
    "{0}: {1}" -f $_, if (Test-Path $_) { (Get-ItemProperty $_).'(default)' } else { 'MISSING' }
}

# 2. Inspect the OpenWithList MRU for .psm1
Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psm1\OpenWithList"

# 3. Look for IDE-specific ProgIDs hijacking .psm1
Get-ChildItem "HKCU:\SOFTWARE\Classes" | Where-Object { 
    $_.PSChildName -match "psm1|ps1" 
} | ForEach-Object {
    "{0} -> {1}" -f $_.PSChildName, (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).'(default)'
}
```

If `Microsoft.PowerShellModule.1\shell\open\command` is missing AND the OpenWithList MRU has an IDE entry, you've confirmed the issue.

## Fix

Run `Skills/DevOps/Fleet/Fix-PowerShellFileAssociation.ps1` (no admin required — operates entirely in HKCU):

```powershell
. Skills/DevOps/Fleet/Fix-PowerShellFileAssociation.ps1
```

The script:
1. Sets `HKCU:\SOFTWARE\Classes\.psm1` default → `Microsoft.PowerShellModule.1`
2. Creates `Microsoft.PowerShellModule.1\shell\open\command` → `pwsh.exe -NoExit -Command "Import-Module '%1'"`
3. Same for `.ps1` and `Microsoft.PowerShellScript.1`
4. Clears Antigravity from the `.psm1` OpenWithList MRU

Idempotent — re-run after IDE updates that may reset the associations.

## Why HKCU is sufficient (no admin needed)

Most modern IDE installers (Antigravity, Cursor, Trae) register their file associations per-user in `HKCU:\SOFTWARE\Classes\`, not system-wide. User-level overrides in `HKCU` take precedence over system-level. Setting both the `.psm1` default and the proper ProgID's `shell\open\command` in `HKCU` is enough to win against the IDE's per-user registrations.

## When HKCU is NOT sufficient

If the IDE's installer writes to `HKLM:\SOFTWARE\Classes\`, you'll need elevation. Check with:

```powershell
Get-ChildItem "HKLM:\SOFTWARE\Classes" | Where-Object { $_.PSChildName -match "Antigravity|psm1" }
```

If those exist, run the system-level fix in an Administrator PowerShell:

```powershell
cmd /c assoc .psm1=Microsoft.PowerShellModule.1
cmd /c ftype Microsoft.PowerShellModule.1="C:\Program Files\PowerShell\7\pwsh.exe" -NoExit -Command "Import-Module '%1'"
```

## Cross-references

- `Skills/DevOps/Fleet/Fix-PowerShellFileAssociation.ps1` — idempotent fix utility
<!-- doc-lint: exempt -->
- `Tasks/Manual/2026-06-14-fix-psm1-file-association.md` — manual fix steps for users who can't run the script
- `Tasks/Complete/Prompts/2026-06-08 - Stop .psm1 popups during Orchestrate_Redeploy.json` — original user report of the same issue
- `Skills/Workflows/Code/workflow.md § Lessons Learned — 2026-06-14` — session context

## Red lines

- **Don't delete the IDE's custom ProgIDs** (e.g., `Antigravity.psm1`). The installer recreates them on next launch. The fix is to add a working PowerShell handler that takes precedence.
- **Don't `cmd /c ftype` without verifying the path** to `pwsh.exe` first. An incorrect path silently fails the fix.
- **Don't modify `HKLM` without elevation** — the change is silently rejected.

## Completion

Fix is complete when:
- `Invoke-Pester Skills/Docker/Tests/BundleDrift.Tests.ps1` runs to completion (confirms `Import-Module` works via the new handler)
- Double-clicking a `.psm1` file in Explorer opens pwsh and imports the module (no IDE, no dialog)
- `Get-ItemProperty "HKCU:\SOFTWARE\Classes\.psm1"` shows the default as `Microsoft.PowerShellModule.1`
