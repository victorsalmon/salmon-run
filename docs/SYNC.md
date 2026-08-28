# salmon-run — Canonical Sync Guide

> Status: **Published guide for the public `salmon-run` package.**

This document describes how the public `salmon-run` package is maintained as a
scrubbed mirror of the private `salmon-orchestrator` canonical source, and how
public contributors can report a leak.

---

## Source-of-truth

| Repo | URL | Visibility | Role |
|------|-----|------------|------|
| **`salmon-orchestrator`** | Private | 🔒 Private | Canonical source of truth. All feature development, bug fixes, and iteration happen here. |
| **`salmon-run`** | `https://worktree.ca/clocklobster/salmon-run.git` / `https://github.com/clocklobster/salmon-run.git` | 🔓 Public | Scrubbed, generalized public mirror. Projected from canonical via `Sync-FromCanonical.ps1` with runtime scrub. |

The canonical `salmon-orchestrator` repo is the active source of truth.
`salmon-run` is rebuilt from it periodically and retains divergence only for
public-package-specific changes (docs, CI workflows, public tooling).

---

## Sync cadence

Sync is performed manually or triggered by a canonical release:

| Trigger | Cadence | Action |
|---------|---------|--------|
| **Canonical release** | Each `salmon-orchestrator` release | Full sync + leak check + release of `salmon-run` |
| **Bug-fix backport** | As needed | Cherry-pick specific commits with leak scrub |
| **Periodic catch-up** | Monthly or before a `salmon-run` release | Full sync to incorporate canonical improvements |

---

## Sync procedure

### 1. Set up the canonical remote

```powershell
# One-time: add the canonical remote (path or URL)
git remote add canonical <path-to-salmon-orchestrator>
```

### 2. Run the sync script

```powershell
.\scripts\Sync-FromCanonical.ps1 -CanonicalRepo <canonical-path>
```

This script:

1. Copies `Modules/` (the `SalmonRun.*` modules) and `Skills/` from the
   canonical repo into the public repo, preserving public-only layout.
2. Applies a runtime text scrub (see `scripts/Sync-FromCanonical.ps1`, the
   `$privatePatterns` array and the `Invoke-ScrubString` helper) that removes:
   - User profile paths (the `$env:USERPROFILE` value)
   - Windows `C:\Users` usernames
   - Internal hostnames and FQDNs (`worktree.ca/...`, `github.com/...`)
   - Credential-like strings (`token=`, `key=`, `secret=`, `password=`,
     `api_key=` assignments)
   - Internal fleet references and private URLs
3. Runs `Invoke-LeakCheck.ps1` automatically.

### 3. Run the leak check manually (if not run by sync)

```powershell
.\scripts\Invoke-LeakCheck.ps1
```

Expected output:

```
No private references found in scanned files.
```

Any hit **MUST** be fixed before committing. The leak check scans all files
except the checker (`Invoke-LeakCheck.ps1`) and the sync script
(`Sync-FromCanonical.ps1`) themselves.

### 4. Run the full test suite

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```

Confirm: 549+ passed, 0 failed, 3 skipped (or better).

### 5. Run the documentation lint

```powershell
.\Tools\Documentation\Scripts\Invoke-DocLint.ps1 -RepoRoot .
```

Confirm: 0 broken references.

### 6. Commit with a descriptive message

```bash
git add -A
git commit -m "sync: pull from canonical with leak scrub"
git push origin main
```

---

## Scrub rules

The sync script (`Sync-FromCanonical.ps1`) applies the following regex-based
scrub patterns. These rules are defined in the script's `$privatePatterns`
array inside the `Invoke-ScrubString` helper, and every match is replaced with
the literal `{{REDACTED}}`:

| Category | Pattern | Matches |
|----------|---------|---------|
| User profile paths | `$env:USERPROFILE` (regex-escaped) | The current user's home directory, e.g. `C:\Users\jdoe` |
| Windows `C:\Users` usernames | `C:\\+Users\\+[^\\]+` | `C:\Users\jdoe`, `C:/Users/jdoe` |
| Internal hostnames / FQDNs | `worktree\.ca/[^\s]+` | `worktree.ca/clocklobster/salmon-run` (private host) |
| Public-origin host references | `github\.com/[^\s]+` | `github.com/...` paths that should not appear in scrubbed text |
| Credential-like strings | `(?i)\b(token\|key\|secret\|password\|api_key)\s*=\s*[^\s\r\n]+` | `token=abc123`, `api_key=sk-...`, `password=hunter2` |

Text files matching `*.ps1`, `*.psm1`, `*.psd1`, `*.json`, `*.md`, `*.yml`,
`*.yaml`, `*.env`, and `*.txt` are scrubbed on copy; all other files are
copied verbatim. To add or modify scrub patterns, edit the `$privatePatterns`
array in `scripts/Sync-FromCanonical.ps1`.

---

## Reporting a leak

If you find a private hostname, user path, token, or credential in the public
`salmon-run` repo:

1. **Do not post it publicly.** Email the maintainers or file a private issue.
2. **Describe what you found** and which file(s) contain it.
3. **The maintainers will:**
   - Confirm the leak.
   - Remove or redact the reference.
   - Update the scrub rules in `Sync-FromCanonical.ps1` to catch it in future
     syncs.
   - Release a patch if the leak is in a published artifact.

---

## Divergence policy

`salmon-run` may contain changes not in `salmon-orchestrator` when those
changes are specific to the public package:

- **Allowed**: CI workflow files (`.github/`, `.worktree/`), public docs,
  `install.ps1`, public-only scripts, README, `AGENTS.md`.
- **Allowed with care**: Test files that mock external providers (contract
  tests) rather than hitting live APIs.
- **Not allowed**: Credentials, hostnames, client paths, internal fleet
  references, feature code that cannot be generalized to any environment.

When a canonical sync overwrites a public-specific file, the change should be
re-applied and documented in the sync commit message.