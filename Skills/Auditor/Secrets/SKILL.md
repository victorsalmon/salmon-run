---
name: opencode/secret-audit
description: Audit codebase for secret leakage vectors: hardcoded credentials, execSync secret exposure, unmasked token output, insecure TLS defaults. Covers scanning, fixing, and verification.
type: workflow
flavor: opencode
loaded_by: any opencode CLI session
container: opencode
---
# Secret Security Audit — opencode workflow

**Type**: workflow
**Flavor**: opencode
**Loaded by**: any opencode CLI session
**Registered in**: skills.json

## Purpose
Audit codebase for secret leakage vectors: hardcoded credentials, secrets exposed in process listings (execSync with secret IDs), unmasked token output, and insecure TLS defaults. Fixes found issues with SDK-based retrieval, token masking, and configurable TLS validation.

## Trigger
- User says "audit secrets", "secret audit", or "check for secret leakage"
- After modifying authentication, credential handling, or API key retrieval code
- During code review or pre-deployment security check

## Workflow Steps

### Step 1: Scan for execSync with secret exposure
Search for `execSync` or `execFileSync` calls that pass secret IDs, API keys, or credentials as command-line arguments:

```powershell
Select-String -Path @(targetFiles) -Pattern "execSync.*secretsmanager|execSync.*get-secret"
```

For each finding:
- Replace with AWS SDK `GetSecretValueCommand` (`@aws-sdk/client-secrets-manager`) or `execFileSync` with env-var-based profile
- Create a shared helper at `Skills/Bookkeeping/Scripts/shared/lib/get-secret.js` for centralized secret retrieval
- Import the helper from all consuming scripts

### Step 2: Scan for unmasked token output
Search for `Write-Host`, `console.log`, or `print` statements that output full token/API key values:

```powershell
Select-String -Path @(targetFiles) -Pattern "Write-Host.*TOKEN.*\$|console\.log.*(api_key|token|secret)"
```

For each finding:
- Mask output to show only last 4 characters: `$($value.Substring($value.Length - 4))`
- Verify the masking pattern is applied

### Step 3: Scan for insecure TLS/SSL defaults
Search for `rejectUnauthorized: false` or `tlsOptions` with disabled validation:

```powershell
Select-String -Path @(targetFiles) -Pattern "rejectUnauthorized:\s*false|tlsOptions"
```

For each finding:
- Set `tlsOptions: { rejectUnauthorized: true }` unconditionally — IMAP credential transport must always verify certificates
- Do NOT add an env-var opt-out (e.g. `IMAP_TLS_REJECT_UNAUTHORIZED`) — no runtime knob may disable verification
- If the host uses a private CA, add the CA to the image trust store instead of disabling verification

### Step 4: Scan for hardcoded API base URLs
Search for hardcoded vendor API URLs:

```powershell
Select-String -Path @(targetFiles) -Pattern "api\.(tavily|firecrawl|zoho|hunter|apollo)\.|api\.smartlead\.ai"
```

For each finding:
- Read from an env var with the hardcoded URL as default
- Use the env var in the function body, not the hardcoded string

### Step 5: Verify all fixes
Run syntax checks and pattern verification:

```powershell
node --check Infrastructure/web-mcp-server.js
Select-String -Path "Skills/Docker/config.ps1" -Pattern 'Write-Host.*Browserless.*TOKEN.*\$newToken'
```

## Red lines
- **Do not commit credentials**: Never log or commit secret values. All audit output must be masked.
- **Read-only AWS Secrets Manager**: Same policy as AGENTS.md — no writes to AWS SM.
- **Preserve existing behavior**: Fix the leakage vector, not the business logic. Test with syntax checks.
- **script exists check**: Before referencing a script in the skill, verify on disk.

## Key cross-references
- `Skills/Bookkeeping/Scripts/shared/lib/get-secret.js` — shared secret retrieval helper
- `Skills/Docker/Scripts/Rotate-ApiKeys.ps1` — key rotation scaffold
- `AGENTS.md` — AWS SM read-only policy

### Lessons Learned — 2026-06-12

**What Worked**:
- Phased approach (scan → fix → verify) ensured systematic coverage
- `node --check` caught syntax errors after every JS edit
- Shared helper pattern avoided duplication: one `get-secret.js` imported by 6 scripts

**What Didn't Work**:
- `Select-String -SimpleMatch` with patterns containing special characters (`|`) can miss matches; use regex pattern instead
- PowerShell string interpolation with `${files.Count}` syntax is fragile

**Improvements for next run**:
- Pre-verify all target files exist before starting the scan
- Use `rg` (ripgrep) for cross-platform consistency instead of `Select-String`

## Completion
Reports completion after all 5 steps. Does not enter drain/poll loop — single pass.
