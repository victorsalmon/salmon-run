# salmon-run — Release Guide

> Status: **Published guide for the public `salmon-run` package.**

This document describes how the public `salmon-run` package is released,
what artifacts are produced, and the checklist that must pass before each
release.

---

## Artifact set

`salmon-run` distributes three complementary artifacts:

| Artifact | Distribution | Install command | Audience |
|----------|-------------|-----------------|----------|
| **GitHub source archive** | [GitHub releases](https://github.com/victorsalmon/salmon-run/releases) | `git clone --branch <tag> https://github.com/victorsalmon/salmon-run.git && .\install.ps1` | Developers who want to inspect, fork, or contribute |
| **PowerShell Gallery module** | [PowerShell Gallery](https://www.powershellgallery.com/packages/SalmonRun) | `Install-Module -Name SalmonRun` | PowerShell users who want the whole control plane as one meta-module |
| **Docker image** | GHCR or Docker Hub | `docker pull ghcr.io/victorsalmon/salmon-run:<tag>` | Container-first and CI users |

Each artifact is built from the same Git tag and carries the same version.

---

## Versioning policy

- **Format**: `v<major>.<minor>.<patch>` (e.g. `v0.1.5`)
- Compatibility, breaking changes, and patches follow [Semantic Versioning 2.0](https://semver.org/).
- A release **MUST** have a signed, annotated Git tag.

## Live validation notes

The public `salmon-run` package was validated at `v0.1.5` on 2026-08-27:

- Docker image built locally as `salmon-run:0.1.5` and `docker run --rm salmon-run:0.1.5 -DryRun` produced the expected queue listing.
- The `SalmonRun` PowerShell Gallery meta-module manifest was validated with `Test-ModuleManifest` and a local `nupkg` was produced via `scripts/Publish-SalmonRunModule.ps1 -LocalRepository`.
- Live provider contract tests passed for OpenCode, Devin, and DSH (via OpenRouter) with real API keys resolved through `SalmonRun.Credentials`.
- Live GitCloud contract tests pushed a disposable branch to `https://github.com/victorsalmon/salmon-run.git` (using the authenticated GitHub token) and `https://worktree.ca/clocklobster/salmon-run.git`.
- GitHub release, GHCR, and PowerShell Gallery *publication* were not performed because the required publish credentials (`POWERSHELL_GALLERY_KEY`, `DOCKER_TOKEN`, a release-creating GitHub token) are not configured in the validation environment. The CI workflows are ready to publish when a `v*` tag is pushed with those secrets.

---

## Pre-release checklist

Before cutting a release, every item below **MUST** pass:

### 1. Test suite green

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```

- **Result**: 587+ passed, 0 failed, 8 skipped (or better).
- Failures block the release.

### 2. Leak check clean

```powershell
.\scripts\Invoke-LeakCheck.ps1
```

- **Result**: "No private references found in scanned files".
- Any hit is a blocker — fix before release.

### 3. Documentation lint clean

```powershell
.\Tools\Documentation\Scripts\Invoke-DocLint.ps1 -RepoRoot .
```

- **Result**: "Documentation Lint: PASS; Scanned: N files, 0 broken refs".

### 4. Provider contract tests pass

Each provider contract test **MAY** skip the live path (guarded by
`SALMON_RUN_<PROVIDER>_LIVE=1`), but the mocked unit tests **MUST** pass:

```powershell
Invoke-Pester -Path .\Tests\SalmonRun.PondEngine.OpenCode.Contract.Tests.ps1
Invoke-Pester -Path .\Tests\SalmonRun.PondEngine.Devin.Contract.Tests.ps1
Invoke-Pester -Path .\Tests\SalmonRun.PondEngine.Dsh.Contract.Tests.ps1
```

### 5. GitCloud contract tests pass

```powershell
Invoke-Pester -Path .\Tests\SalmonRun.GitCloud.Contract.Tests.ps1
```

### 6. Docker build passes

```powershell
docker build -t salmon-run .
docker run --rm salmon-run -DryRun
```

- **Result**: `Salmon Run dry run` output with queues listed.
- Build failures block the release.

### 7. Installer smoke test

```powershell
.\install.ps1
Start-SalmonRun.ps1 -DryRun
```

- **Result**: Queues listed from `~/.salmon`.

---

## Release steps

### 1. Prepare the release branch

```bash
git checkout main
git pull --rebase
# Run the full checklist above.
```

### 2. Tag the release

```bash
git tag -s v<major>.<minor>.<patch> -m "salmon-run v<major>.<minor>.<patch>"
git push origin v<major>.<minor>.<patch>
```

### 3. Build and publish artifacts

#### GitHub release

The `.github/workflows/test.yml` workflow creates a GitHub release and attaches
the source archive when a version tag is pushed.

```bash
# Manual alternative:
gh release create v<version> --title "salmon-run v<version>" --notes "<release-notes>"
```

#### PowerShell Gallery

The published package is the `SalmonRun` meta-module (`Modules/SalmonRun/SalmonRun.psd1`),
which declares every `SalmonRun.*` submodule as a `RequiredModules` dependency so a
single `Import-Module SalmonRun` brings the full control plane online.

```powershell
# From the repo root, using the helper (builds nupkg locally when no key is set):
.\scripts\Publish-SalmonRunModule.ps1 -NuGetApiKey $env:POWERSHELL_GALLERY_KEY

# Or directly:
Publish-Module -Path .\Modules\SalmonRun -NuGetApiKey $POWERSHELL_GALLERY_KEY
```

#### Docker image

```bash
docker build -t ghcr.io/victorsalmon/salmon-run:<version> .
docker push ghcr.io/victorsalmon/salmon-run:<version>
docker tag ghcr.io/victorsalmon/salmon-run:<version> ghcr.io/victorsalmon/salmon-run:latest
docker push ghcr.io/victorsalmon/salmon-run:latest
```

### 4. Verify a clean install

```powershell
# Fresh PowerShell session:
Install-Module -Name SalmonRun
Start-SalmonRun.ps1 -DryRun
```

Or from a fresh clone:

```powershell
git clone https://github.com/victorsalmon/salmon-run.git --branch v<version>
cd salmon-run
.\install.ps1
.\Start-SalmonRun.ps1 -DryRun
```

---

## Rollback

If a release exhibits a blocking defect:

1. **Do not delete the release tag.** Mark it as `prerelease` on GitHub.
2. **Publish a patch release** (`v<major>.<minor>.<patch+1>`) with the fix.
3. **Update the `latest` Docker tag** to point at the patch release.
4. **Unlist the broken PowerShell Gallery version** through the Gallery admin UI.

The pre-release checklist is designed to catch defects before rollback is
needed. If a rollback occurs, add the root cause to the checklist as a new
precondition.

---

## Maintainers

Release credentials are resolved through `~/.salmon/.env` via
`SalmonRun.Credentials` and are never committed to the repo.

| Credential | Resolver | Purpose |
|------------|----------|---------|
| `POWERSHELL_GALLERY_KEY` | `Env`, `File`, or `AWS` | Publish the PowerShell Gallery module |
| `GITHUB_TOKEN` | `Env` | `gh release create` and `git push` |
| `DOCKER_TOKEN` or `docker login` credentials | `Env` | Push the Docker image |

See `dot-salmon.example/.env.example` for resolver syntax.

---

## Canonical-source sync

`salmon-run` is a scrubbed public mirror of the private `salmon-orchestrator`
repo. See `docs/SYNC.md` for the sync cadence, scrub rules, and leak-check
procedure.