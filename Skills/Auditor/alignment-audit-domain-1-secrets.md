# Domain 1: Secrets + Port Registry Alignment

**Purpose**: Ensure all sources of truth for secrets — `install.json`, `bundle-manifest.ps1`, `env-var-registry.json`, `docker-manifest.json`, and `Agents/*/agents.md` secrets tables — agree on which secrets exist, where they come from, and which services consume them.

**Trigger**: Run this survey when:
- Adding or removing a secret from any manifest
- Changing a secret's source (AWS SM → env-var → auto-generated)
- Updating `install.json` features
- After any deployment that mounts new secrets

**Survey procedure**:

1. **Extract canonical key set**: Read `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` and collect all `SourceKeys` from every bundle type (ORCH, VERI, BASE, Sentry, Coding, Proxy, WebMcp). This is the authoritative list.

2. **Check install.json coverage**: Verify every SourceKey appears in `install.json.features.*.secrets` under an installed (`"install": true`) feature. Keys that are in SourceKeys but missing from install.json are gaps. Keys in install.json but not in SourceKeys are orphaned (unless they're non-bundle secrets like `TAILSCALE_KEY`, `BROWSERLESS_TOKEN`).

3. **Check secret values against env-var-registry**: For each install.json secret with value starting with `AWS/`:
   - Look up the key in `docs/Reference/env-var-registry.json`
   - If `hydratedFromAws: false`, flag inconsistency — the key is either auto-generated, env-var-sourced, or misclassified
   - If `hydratedFromAws: true`, verify the key actually exists in the AWS SM secret (`Interclaw/{Project}/Provisioning` or `Interclaw/{Project}/Orchestrator`)
    - If no registry entry exists, add one

    > **AWS limitation**: Steps 3–4 require an active AWS SSO session (initialized by Phase 4 of `0setup.ps1`). If AWS credentials are unavailable in the current session, skip steps 3–4 and log a finding: `Write-Finding -Domain domain-1 -Severity info -Title "AWS SM verification skipped" -Detail "No active SSO session. Manual verification required: run aws sso login then re-run Domain 1 step 3."`. The env-var-registry cross-check in step 3 can still be performed for `hydratedFromAws: true/false` consistency against `install.json`; the AWS SM existence check is the only sub-step that requires live credentials.

4. **Check docker-manifest.json bundle contents**: For each bundle type in `Infrastructure/manifests/docker-manifest.json`, verify the `contains` array matches the SourceKeys from bundle-manifest.ps1. Missing keys and extra keys are both findings.

5. **Check agent.md secrets tables**: For each `Agents/*/agents.md`, verify the "Secrets Mounted" column per service matches docker-manifest.json `consumedBy` and `contains`. Agents should only list secrets their service actually receives.

6. **Scan for plaintext credential files on disk**: Recursively search `Skills/Bookkeeping/Scripts/`, `CriticalPath/`, and any repo subdirectory for files matching `.zoho-creds.json`, `.token.json`, `*cred*`, `*secret*`, `*auth*.json`, and any dotfile with JSON that may contain cached credentials. If found:
   - Read the file to ensure credentials are still valid
   - Delete the file immediately
   - Log a finding to the Findings Manifest via `Write-Finding -Domain domain-1 -Severity high -Title "Plaintext credential file on disk" -Files @("<path>") -Detail "..."`
   - Verify the upstream script that created it has been fixed to use in-memory credential resolution only (no disk cache)

   > **Allowed exception**: The `FRAD_zoho_token_cache` Docker volume (managed by `zoho-token-cache.js`) stores short-lived OAuth access tokens in Docker-managed encrypted storage, not raw host filesystem. This does not count as a finding. Inspect its contents via `docker run --rm -v FRAD_zoho_token_cache:/cache alpine cat /cache/.zoho-token.json` to verify it contains only an access token with expiry, not long-lived secrets.

7. **Log findings**: Write each inconsistency to the Findings Manifest via `Write-Finding`. Also write a corresponding entry to the audit log for hash-chain traceability.

**Scoring**:
- **Critical**: A secret that should be in AWS SM is missing → containers deploy without required credentials
- **High**: install.json and env-var-registry disagree on hydration source → wrong resolution path
- **Medium**: agent.md or docker-manifest has outdated secret lists → doc debt
- **Low**: Missing env-var-registry entry for a key that exists in other manifests
