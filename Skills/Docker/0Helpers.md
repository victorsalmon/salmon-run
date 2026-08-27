# 0Helpers.ps1

Compatibility redirector for the ORCHESTRATOR shared helper module.

## Purpose

This file is a **backward-compatibility redirector**. All shared functions have moved to `Modules/ORCHESTRATOR.Core/ORCHESTRATOR.Core.ps1`.

## Behavior

1. Constructs the path to `Modules/ORCHESTRATOR.Core/ORCHESTRATOR.Core.ps1` relative to `$PSScriptRoot`
2. If the module exists, dot-sources it into the current scope
3. If the module is missing, throws an error with the expected path

## Usage

```powershell
# Deprecated — use this instead:
. (Join-Path $PSScriptRoot "..\Scripts\Modules\ORCHESTRATOR.Core\ORCHESTRATOR.Core.ps1")

# Old way (still works via redirector):
. (Join-Path $PSScriptRoot "0Helpers.ps1")
```

## Notes

- All new scripts should dot-source `Modules/ORCHESTRATOR.Core/ORCHESTRATOR.Core.ps1` directly
- This redirector exists to avoid breaking legacy scripts that still reference `0Helpers.ps1`
