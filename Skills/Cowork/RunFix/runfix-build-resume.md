# Skill: RunFix Goals - `build-resume`

**Purpose**: Goals file for `RunFix build-resume.ps1` - defines what success looks like, what errors to expect, and how to verify the resume vault is healthy after a run.

**Convention**: This file lives at `Skills/Cowork/RunFix/runfix-build-resume.md`.

**Generic engine**: `Skills/Cowork/RunFix/runfix.md`

---

## Configuration (Script Mode)

| Hook | Value |
|------|-------|
| `$MODE` | `"script"` |
| `$TARGET_SCRIPT` | `C:\Repos\resume\tools\build-resume.ps1` |
| `$LOG_PREFIX` | `runfix-build-resume` |
| `$POLL_INTERVAL_SECONDS` | `60` |
| `$MAX_WALL_MINUTES` | `60` |
| `$TIMEOUT_SECONDS` | `300` |

### Flags to pass

```powershell
& 'C:\Repos\resume\tools\build-resume.ps1'
```

(No flags = build mode. Use `-Validate` to check coverage/freshness instead.)

---

## Success Criteria

| # | Condition | Evidence |
|---|-----------|----------|
| 1 | Build completes with exit code 0 | Process exit code 0 |
| 2 | Every top-level `Resumes/*.md` has a `.docx` sibling | `Get-ChildItem C:\Repos\resume\Resumes -Filter *.docx` covers all `.md` basenames |
| 3 | Every generated `.docx` is a valid zip | First two bytes are `50 4B` (`PK`) |
| 4 | Re-running is deterministic and idempotent | Second run produces byte-identical `.docx` (SHA256 hash unchanged) |
| 5 | `-Validate` exits 0 (only documented PDF warnings allowed) | `& build-resume.ps1 -Validate; $LASTEXITCODE -eq 0` |

---

## Known Error Signatures

| Error signature | Root cause | Fix |
|-----------------|------------|-----|
| `python not found - install dependencies from tools/requirements.txt` | python-docx not installed on host | `python -m pip install -r C:\Repos\resume\tools\requirements.txt` |
| `render failed for <resume>.md` | Renderer threw (e.g. unreadable markdown, output locked by Word) | Read the exception; close the open `.docx` in Word; fix the `.md` structure; re-run |
| `Validation FAILED: <N> failure(s)` with `MISSING:` entries | A `.docx`/`.pdf` required by the coverage policy does not exist | Run build mode to regenerate; if `.pdf`, export manually from Word |
| `Validation FAILED: <N> failure(s)` with `STALE:` entries | Artifact's last git commit is older than its source `.md` | Re-run build mode, then commit the regenerated artifact |
| `STALE (PDF requires manual Word export): <file>.pdf` | PDF committed before its `.md`; toolchain cannot render PDFs | Warning only (documented exception, README coverage policy); export from Word when the resume is next updated |
