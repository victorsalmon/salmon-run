# Environment-Specific Tasks

Load this file when listing task files to filter by environment. Some task files are scoped to a specific deployment environment (FRAD, FRAL). This enables the same repo to serve both environments without agents picking up the wrong tasks.

## Configuration

```powershell
$environments = @("FRAD", "FRAL")
```

## Detection Rule

When listing task files in `Tasks/` root:

1. Split the filename on `-` and take the first segment.
2. Uppercase it and check against `$environments`.
3. If it matches:
   - Read `<project-root>/install.json` and extract `project.code`.
   - If `INSTALL_PROJECT` does **not** match the filename prefix, **skip the task** — it belongs to the other environment.
   - If it matches, strip the environment prefix from the filename and proceed normally (e.g. `FRAL-2026.05.08-task1.md` → process as `2026.05.08-task1.md`).
4. If no match, process the task regardless of environment.

Example: On a FRAD machine, `FRAL-2026.05.08-task1.md` is silently skipped. A file named `2026.05.08-task1.md` with no prefix is processed on both.
