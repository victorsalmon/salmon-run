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

1. Copies `Modules/`, `Tests/`, and `dot-salmon.example/` from the canonical
   repo into the public repo.
2. Applies a runtime text scrub that removes:
   - User profile paths (`C:\Users\<username>`, `/home/<user>`)
   - Windows `C:\Users` usernames
   - Internal hostnames and FQDNs
   - Credential-like strings (tokens, API keys)
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
scrub patterns. These rules are hardcoded in the script's `$scrubPatterns`
parameter:

| Category | Pattern | Example |
|----------|---------|---------|
| User profile paths | `C:\\Users\\[^\\\s"]+` | `C:\Users\jdoe` → `[REDACTED]` |
| Unix home paths | `/home/[^/\s"]+` | `/home/jdoe` → `[REDACTED]` |
| Internal hostnames | `\b(?:internal|fleet|corp)\.example\.com\b` | `internal.example.com` → `[REDACTED]` |
| Credential-like strings | `(?:sk-|ghp_)[a-zA-Z0-9]{20,}` | `sk-proj-abc123...` → `[REDACTED]` |
| Private URLs | `https?://[^/\s]*\.(?:internal|corp)\.` | `https://secrets.internal.corp/` → `[REDACTED]` |

To add or modify scrub patterns, edit the `$scrubPatterns` array in
`scripts/Sync-FromCanonical.ps1`.

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