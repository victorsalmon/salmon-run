# Repair PowerShell File Associations (.ps1 / .psm1)

**Type**: utility
**Flavor**: opencode
**Script**: `Skills/DevOps/Fleet/Fix-PowerShellFileAssociation.ps1` (no admin needed)
**RunFix**: `Skills/Archive/workflow-runfix-runfix-repair-pwsh-associations.md`

## Purpose

Fix `.ps1` and `.psm1` files that open in Notepad/IDE instead of executing with pwsh.exe. Common on clean Windows installs or after IDE installers hijack the file associations.

## Trigger

- `.psm1` / `.ps1` files open in Notepad or an IDE instead of running
- "Pick an app" dialog appears when running PowerShell scripts
- Agent reports `Start-Process` or `Invoke-Item` opening a `.psm1` in an editor

## Fix (no admin needed — HKCU)

```powershell
. Skills/DevOps/Fleet/Fix-PowerShellFileAssociation.ps1
```

This creates the missing `shell\open\command` entries in `HKCU:\SOFTWARE\Classes\` — no elevation required.

If the system-level association is also broken (admin available):

```powershell
& "Skills/Documentation/Scripts/Repair-PowerShellFileAssociations.ps1"
```

## Cross-references

- `Skills/DevOps/Fleet/Fix-PowerShellFileAssociation.ps1` — HKCU-only, no admin needed
- `Skills/Documentation/Scripts/Repair-PowerShellFileAssociations.ps1` — system-level `assoc`/`ftype`, admin required
- `Skills/Archive/workflow-runfix-runfix-repair-pwsh-associations.md` — RunFix goals
