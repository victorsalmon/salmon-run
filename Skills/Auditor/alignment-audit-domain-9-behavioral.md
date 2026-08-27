# Domain 7: Behavioral Invariants

**Purpose**: Verify that cross-cutting behavioral guarantees hold — properties that span multiple modules, functions, or execution contexts and cannot be verified by single-file static analysis or automated grep patterns.

> **Note**: Four previously tracked invariants have been removed as they are now covered by the automated pre-flight sweep:
> - Invariant 2 (Atomic file writes) → automated scan scans for direct writes without temp-file pattern
> - Invariant 5 (Pinned Docker base tags) → automated scan checks `FROM` statements for floating tags
> - Invariant 8 (Canonical section headings: `## Constraints`) → automated scan checks for non-canonical headings
> - Invariant 9 (Lessons Learned format) → automated scan checks for level-2 `## Lessons Learned`

**Trigger**: Every audit cycle. Runs after Domains 2 and 3 (which may modify files this domain checks).

**Scoring**: Invariant violations are always at least High severity — they represent guarantees that code or documentation explicitly depends on.

| Invariant | Blast radius |
|-----------|--------------|
| 1. Idempotent deployment pipeline | Critical — re-run failure halts all future deployments |
| 2. Credential swap restores env | Critical — unrecoverable credential leak |
| 3. Volume init stable compose | High — unreproducible deployments |
| 4. Timeout chains nest correctly | Medium — hard-to-diagnose intermittent failures |
| 5. Secret bundle key match | High — undocumented key access fails silently |

### Invariant 1: Idempotent deployment pipeline
**Guarantee**: Running `deploy.ps1` twice in sequence on the same `install.json` produces the same final state and does not error on the second run.
**Verification**: Run `./Skills/Docker/deploy.ps1 -Phase DryRun 2>&1` (or a subset phase). Compare output with prior run's snapshot. If the script modifies state that changes between runs (e.g., rotating IAM keys), the invariant narrows to: "No operation errors on re-run; new state is functionally equivalent to old state."
**Scope**: `Skills/Docker/deploy.ps1`, `Skills/Docker/1*.ps1`

### Invariant 2: Credential swap restores original env
**Guarantee**: `Invoke-WithCredentialSwap` always restores `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_PROFILE`, `AWS_DEFAULT_PROFILE`, `AWS_CONFIG_FILE`, and `AWS_SHARED_CREDENTIALS_FILE` to their pre-swap values, even if the script block throws.
**Verification**: Read `Invoke-WithCredentialSwap.ps1` and verify there is a `try/finally` (or equivalent) that saves and restores all 7 variables. Check there are no early-return paths that skip the `finally` block.
**Scope**: `Skills/Docker/Modules/SalmonRun.Provision/Public/Invoke-WithCredentialSwap.ps1`

### Invariant 3: Volume init produces stable compose output
**Guarantee**: Running `Initialize-AgentVolumes.ps1` followed immediately by `New-FleetCompose.ps1` produces the same docker-compose YAML regardless of how many times it's run (assuming identical `install.json`).
**Verification**: Run both functions, checksum the generated YAML, re-run, verify the checksum matches.
**Scope**: `Skills/Docker/Modules/SalmonRun.Deploy/Public/Initialize-AgentVolumes.ps1`, `New-FleetCompose.ps1`

### Invariant 4: Timeout chains nest correctly
**Guarantee**: When an operation has timeouts at multiple layers (HTTP call → Wait-Job → caller timeout), each inner timeout is strictly shorter than its outer timeout. A 30-second HTTP call inside a 10-second Wait-Job will always time out.
**Verification**: For every `Wait-Job -Timeout N` and `Invoke-RestMethod -TimeoutSec N` pair in the same call chain, verify inner N < outer N.
**Scope**: `Skills/Docker/Modules/Interclaw.*/Public/*.ps1`

### Invariant 5: Secret bundles contain only documented keys
**Guarantee**: Every Docker Swarm secret bundle's runtime contents match its `contains` list in `docker-manifest.json`. No undocumented secrets leak into a bundle.
**Verification**: For each bundle, read the mounted bundle file at runtime and compare its keys against `docker-manifest.json`'s `contains` array.
**Scope**: `Infrastructure/manifests/docker-manifest.json`, runtime bundle inspection

### Logging

Log each verified invariant with `action: "invariant-pass"` or `"invariant-fail"`. A failed invariant must log a finding via `Write-DraftPlan`. The finding includes the invariant number and title (e.g. "Invariant 1: Idempotent deployment pipeline"), the observed failure, and the files that would need changes.
