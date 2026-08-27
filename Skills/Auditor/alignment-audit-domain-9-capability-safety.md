# Domain 9: Capability Safety Drift

**Purpose**: Detect drift from the project's capability-based safety model (ADR-0039) — eroded enforcement layers, trust-based shortcuts, bypassed gates, and credential scope creep that accumulate between audits.

**Trigger**: Every audit cycle. Runs after Domains 2 and 3 complete (paired with D7 in Wave 4).

**Prerequisites**: Load automated scan results. Read ADR-0039 enforcement map.

**Scoring**:

| Severity | Meaning |
|----------|---------|
| **Critical** | Capability model is broken — a trust-based pattern has replaced a capability gate with no compensating control |
| **High** | Partial bypass — a layer is weakened but not fully broken (broader scope than documented, shared credential, missing audit) |
| **Medium** | Documentation debt — a capability gap is undocumented or the enforcement map is stale |
| **Low** | Observation — a pattern that *could* become drift under pressure (single-service credentials, no rotation schedule) |

---

## Survey Procedure

### 1. IAM Policy Drift

Compare IAM policies in `Infrastructure/Policies/` against the baseline documented in their associated ADRs and the fleet topology.

- Grep for new or widened `Action` statements — flag any that grant `*` actions or cover resources outside the principal's scope
- Grep for `Resource: "*"` — flag any that are not explicitly justified in an ADR
- Check that credential isolation tests (e.g., `AWSConfig` test fixture) pass for every IAM user
- Cross-reference against ADR-0007 and ADR-0039 enforcement map Layer 1

### 2. Token Scope Creep

Verify every service token, API key, and PAT in the system has not silently expanded its scope.

- Check GitHub PAT scopes via `gh api /user/repository-invitations` or review `.env` — flag repos with `delete_repo`, `admin:org`, or similar broad scopes
- Check Attio key scopes — verify read key is read-only, write key can create/update only, archive key can soft-delete only (ADR-0008)
- Check per-service bearer tokens — verify no token is shared between services (ADR-0035)
- Cross-reference against ADR-0039 Layer 2

### 3. New Service Gate Analysis

For any new container, service, or sidecar added since the last audit:

- Verify it routes write-capable third-party API calls through `is-api` (ADR-0039 Layer 5)
- Verify it does not mount `/var/run/docker.sock` (ADR-0039 Layer 4)
- Verify it receives only its own role-scoped credentials (ADR-0039 Layer 6)
- Verify it is on the correct overlay network (ADR-0039 Layer 8)
- Verify its API endpoints have bearer-token auth middleware (ADR-0039 Layer 2)

### 4. Plaintext Credential Scan

Grep for hardcoded credentials, `.env` files, or credential files committed to the repo:

- `git grep -n -E '(api[_-]?key|secret|password|token|credential)\s*['':]=\s*[''"][^'^'']+['''']' -- ':!*.md' ':!Skills/Docker/Tests/' ':!Infrastructure/manifests/'
- Check for committed `.env` files: `git ls-files | grep -i '\.env'`
- Check for credential JSON files: `git ls-files | grep -iE '(credentials|service-account|auth)\.json'`
- Cross-reference against ADR-0039 Layer 3

### 5. Capability Bypass Detection

Examine deployment artifacts for patterns that subvert the capability model:

- Check `docker-compose*.yml` — flag any non-sentry container with `docker.sock` mounts or `privileged: true`
- Check Dockerfiles — flag `COPY --from=...` patterns that could leak secrets from one build stage to another
- Check entrypoint scripts — flag any that source credentials from one service into another
- Check `bundle-manifest.ps1` — flag any secret key mounted on a container that does not own that role
- Cross-reference against ADR-0039 Layers 4, 5, 6

### 6. Auth Middleware Audit

Verify every HTTP endpoint in every fleet service has correct authentication middleware:

- For each service's route table or handler registry, check that every non-health endpoint requires a valid bearer token
- Check that health/ready endpoints (`/api/health`, `/api/ready`) are explicitly excluded from auth requirements
- Verify the auth middleware validates the token against the service-specific `FLEET_API_TOKEN_*` secret
- Cross-reference against ADR-0035 and ADR-0039 Layer 2

### 7. Enforcement Map Integrity

Cross-reference the running system against ADR-0039's 9-layer enforcement map:

- For each layer, verify at least one concrete enforcement mechanism exists in the current codebase
- If a layer's mechanism has changed (e.g., a new secrets backend, a new token provider), verify the enforcement map is updated
- If a layer has no mechanism (gaps), file a Critical or High finding

---

## Logging

Log each completed survey step with `action: "step-complete"` and the step number. Log any finding via `Write-DraftPlan`:

```powershell
Write-DraftPlan -Domain "domain-9" -Severity <severity> -BlastRadius <blast> `
    -Title "<finding title>" -Detail "<finding detail>" `
    -Files @("<affected-files>")
```

**Guidance**: Every finding's `-Detail` must contain substantive, actionable text — describe what was found, why it matters, and what should be fixed. Do not leave the detail empty or as a placeholder. A finding with an empty description is unusable by the Coder and wastes the audit cycle.

Log overall domain status:

```powershell
Write-AlignmentAuditLog -Domain "domain-9" -Action "phase-complete" -Detail "Survey complete: N findings, N draft plans"
```
