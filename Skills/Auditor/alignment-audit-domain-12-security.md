# Domain 12: Security Architecture & Capability Safety

**Purpose**: Systematic evaluation of the system's security posture across 6 categories: trust boundaries, credential scope, capability gates, defense-in-depth, dependency & cryptography audit, and operational security.

**Trigger**: Run this survey when:
- Adding a new service or container to the fleet
- Changing credential distribution or IAM policies
- After any deployment that changes network topology
- After discovering a security finding during other domains
- As part of every Architectural Audit (Phase 5)

---

## Category 1: Trust Boundaries

Map every trust boundary in the system and verify capability enforcement at each boundary.

**Checks**:
- [ ] Container boundaries: each container is isolated by Docker Swarm network segmentation. Verify no container can access another's secrets or internal endpoints without explicit capability delegation.
- [ ] Network segments: identify all overlay networks (fleet-internal, proxy-to-mcp, accountant-isolated). Verify containers only join networks they need.
- [ ] API surfaces: for every exposed HTTP endpoint, verify auth enforcement. Public-facing endpoints (health, ready) may be unauthenticated; operational endpoints must require bearer tokens.
- [ ] Credential scopes: verify credentials from one trust domain (e.g., fleet Docker socket) cannot be used in another (e.g., agent container).
- [ ] Implicit trust: verify no component trusts network location over tokens, or hostname over auth.

**Finding format**: `TrustBoundary-<N>` — P1 (violation) or P3 (gap in documentation)

---

## Category 2: Credential Scope

Verify every credential in the system is scoped to minimum necessary capability.

**Checks**:
- [ ] IAM policies grant only the actions and resources each principal needs. Read `Infrastructure/Policies/` for all policy documents.
- [ ] API tokens are read-only where writes are not required (Attio has separate read/write/archive keys).
- [ ] Bearer tokens are per-service, not shared (fleet_api_token and fleet_monitor_token are distinct).
- [ ] Provider keys (OpenRouter, opencode-go) are per-role, not pooled. Coding keys only on mcp_opencode and oc-base containers.
- [ ] No hardcoded credentials in source code. Grep for `key\s*=|secret\s*=|password\s*=|token\s*=` in committed files.
- [ ] Zoho Books credentials: OAuth tokens stored in Docker Swarm secrets, never written to disk by production scripts.

**Finding format**: `CredentialScope-<N>` — P1 (hardcoded creds or over-scoped IAM), P2 (documentation drift)

---

## Category 3: Capability Gates

Verify no agent or service holds a capability it does not need.

**Checks**:
- [ ] No coding key on non-coding container: grep opencode.json for provider models on mcp_opencode vs ASE containers.
- [ ] No write-capable third-party key on an agent container (all writes route through is-api — Attio write, Zoho write, etc.).
- [ ] No Docker socket on non-fleet container: verify only `is-fleet` mounts `/var/run/docker.sock`.
- [ ] No cross-role credential provisioning: fleet provisions only its own AWS creds; agent provisioning is handled separately.
- [ ] Secret bundles are scoped per-service: verify `bundle-manifest.ps1` SourceKeys match each container's actual needs (no bundled keys that the container doesn't use).
- [ ] The host orchestrator has no Docker socket access; only `is-fleet` mounts `/var/run/docker.sock`.

**Finding format**: `CapabilityGate-<N>` — P1 (capability leak), P3 (documentation gap)

---

## Category 4: Defense-in-Depth

Verify multiple independent enforcement layers protect critical operations.

**Checks**:
- [ ] Credential hydration requires both AWS SM access AND Docker Swarm secret mount. Compromising one does not grant the other.
- [ ] Container compromise does not grant access to other containers' secrets (each container has its own secret bundle with only its keys).
- [ ] Network segmentation provides a second line of defense beyond credential scoping. Even with valid creds, a container on network A cannot reach services on network B.

- [ ] Rate limiting and circuit breakers are in place for API endpoints (monitor and respond to 429s).
- [ ] Secret rotation procedures exist and are tested (`Rotate-BundleSecret.ps1`, `Invoke-SecretRotation`).

**Finding format**: `DefenseDepth-<N>` — P1 (single point of failure), P3 (missing documentation or testing)

---

## Category 5: Dependency & Cryptography

Evaluate external dependencies and cryptography practices.

**Checks**:
- [ ] External dependencies (npm packages, Docker base images, Python packages) have been scanned for known vulnerabilities. Check for SCA/SAST in CI pipeline.
- [ ] Cryptography usage follows best practices: no custom crypto implementations, proper TLS verification (no `--insecure` or `verify=False`), modern algorithms (no SHA-1, no SSLv3).
- [ ] Docker images use specific digest hashes (not mutable tags) for base images in Dockerfiles. Mutable tags (`:latest`, `:alpine`) are findings.
- [ ] Supply chain: verify Dockerfile COPY/RUN instructions don't introduce unnecessary attack surface (avoid `COPY . .`, prefer specific paths).
- [ ] Node.js dependencies: `npm audit` shows zero critical or high vulnerabilities.
- [ ] PowerShell modules: no `Install-Module` from PSGallery in production code (pins specific versions, verified hashes).

**Finding format**: `DependencyCrypto-<N>` — P1 (known vulnerability), P2 (mutable tag), P4 (outdated but not vulnerable)

---

## Category 6: Operational Security

Evaluate audit trails, error handling, rate limiting, and secrets hygiene.

**Checks**:
- [ ] Audit trails are append-only and tamper-evident. Verify `SalmonRun.Audit` hash-chain implementation.
- [ ] Error messages don't leak sensitive information (stack traces, file paths, environment variables, credential fragments).
- [ ] Secrets are never logged or exposed in error output. Grep for `$error` combined with sensitive parameter names.
- [ ] Rate limiting and circuit breakers are in place for all API endpoints (Fleet API, Tempo API, accountant endpoints).
- [ ] Secret rotation is documented and testable (`Rotate-BundleSecret.ps1`).
- [ ] Docker secrets are ephemeral: no secrets committed to image layers, no secrets in environment variables in compose files.
- [ ] Git hooks or CI checks prevent credential commits (`.gitignore` patterns for `*secret*`, `*cred*`, `.token`).

**Finding format**: `OpSec-<N>` — P1 (credential leak), P2 (missing rate limiting or audit trail gap), P4 (missing tests for rotation)

---

## Finding Format

Each finding follows the Architectural Audit priority hierarchy (P1–P5):

```markdown
**Finding**: <Title>
**Domain**: Domain 12 (Security)
**Category**: <Category 1-6>
**Priority**: P1|P2|P3|P4|P5
**Files**: <paths>
**Detail**: <description of what was found and why it matters>
**Remediation**: <specific action to fix>
```

---

## Cross-References

- ADR-0039 — Capability-Based Safety Model
- ADR-0035 — Secrets Management
- AGENTS.md § AWS Secrets Manager Policy
- AGENTS.md § Platform-First Resolution
- `bundle-manifest.ps1` — Secret bundle definitions
- `Infrastructure/Policies/` — IAM policy documents
- `fleet-topology.md` — Service inventory and credential mounts
- `alignment-audit-domain-1-secrets.md` — Secrets alignment domain (complementary)
