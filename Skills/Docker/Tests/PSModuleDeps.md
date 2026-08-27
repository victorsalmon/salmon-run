# PS Module Dependencies

## Pester

- **Current version**: 6.0.0 (latest stable, per project policy of tracking latest stable unless there's a business reason to pin)
- **Status**: No local patch required. The `GetPesterOs` regression that affected v5.6.0/5.7.1 is fixed in Pester 6.0.0 — `TestDrive:` works cleanly on Windows (verified 2026-07-25).

### Historical patch (v5 — no longer applied)

Pester 5.6.0 and 5.7.1 had a `GetPesterOs` regression that threw `RuntimeException: Unsupported Operating system!` on Windows when tests used `TestDrive:`. A local fix was applied to the `GetPesterOs` function (line 10200 of Pester.psm1) adding a `.NET RuntimeInformation.IsOSPlatform()` fallback after `Get-Variable` checks failed in new script scopes. This patch is no longer needed on Pester 6.

- **Formerly pinned version**: 5.6.0 (patched)
- **Former module location**: `C:\Users\Victor\Documents\PowerShell\Modules\Pester\5.6.0\`
- **Disabled versions**: `5.7.1` — was renamed to `5.7.1.DISABLED` (same bug, also patched)
