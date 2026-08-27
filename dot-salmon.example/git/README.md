# Salmon Run Git / Worktree credential storage

This directory is the canonical runtime location for git-hosting credentials that
Salmon Run consumes.  It lives under `~/.salmon/git/` (or `%SALMON_RUN_HOME%/git/`)
so that tokens are never committed to the repo.

## Pattern

1. Store the Worktree (or Gitea-compatible) repository read/write token in this
directory as a plain file:
   - File: `~/.salmon/git/worktree-api-token`
   - Contents: a single line containing the token only (no newlines, no quotes).

2. Point `~/.salmon/.env` at that file using the `File` resolver:

```env
WORKTREE_HOST=https://worktree.example
WORKTREE_REPO_RW_ACCESS_TOKEN=File ~/.salmon/git/worktree-api-token
```

3. Replace `WORKTREE_HOST` with your real Gitea-compatible host in your local
`~/.salmon/.env`.  Do not edit the public `dot-salmon.example/.env.example` with a
real hostname or token.

## Where the token comes from

The authoritative source depends on your fleet.  Common options:

- AWS Secrets Manager (preferred): a secret such as `my-org/Worktree/Token` with
  a key such as `WORKTREE_REPO_RW_ACCESS_TOKEN`.
- An environment variable stored outside the repo.
- Another credential vault your organization uses.

## Which terminal / site / tool to use

- **Terminal:** PowerShell 7 (`pwsh`) on Windows, or PowerShell Core on
  Linux/macOS.
- **Site:** your Gitea-compatible host (for example, `https://worktree.example`).
- **Remote:** `https://<worktree-host>/<owner>/<repo>.git`.
- **Salmon Run helper:** `Push-WorktreeRepository -Owner <owner> -Repo <repo>
  -Branch <branch>` will resolve the token from `~/.salmon/.env` automatically.
- **Manual `git push` with `GIT_ASKPASS`:**

```powershell
$token = Get-WorktreeToken
$env:GIT_ASKPASS = 'pwsh -NoProfile -Command "return $env:WORKTREE_TOKEN"'
$env:WORKTREE_TOKEN = $token
$env:GIT_TERMINAL_PROMPT = '0'
git push origin main
Remove-Item Env:\WORKTREE_TOKEN, Env:\GIT_ASKPASS, Env:\GIT_TERMINAL_PROMPT
```

## Files in this directory

- `worktree-api-token` — example placeholder.  After you copy `dot-salmon.example`
  to `~/.salmon/`, replace this file with your real token.
