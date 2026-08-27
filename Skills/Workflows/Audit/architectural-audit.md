# Architectural Audit — Audit Mode Domain (Model-Driven)

**Part of**: Audit mode (`Skills/Auditor/SKILL.md`)
**Sibling**: Alignment Audit (`alignment-audit.md`) — 9-domain drift survey
**Trigger**: User says "Architecture Review" or `/archreview`
**Model tier**: Complex (Pro-tier) — the model exercises independent architectural judgment

---

## Overview

The Architectural Audit evaluates the codebase across **5 security-first dimensions** using **model-driven judgment** supported by a targeted static pre-scan. The model reads code and exercises its own architectural judgment; the [Phase 0.5 Code Security & Correctness Scan](architectural-audit-code-security-scan.md) supplies high-confidence candidates (SQL injection, unsafe casts, empty catch blocks, unvalidated inputs, hardcoded secrets) for the model to validate and classify. Security is not a separate phase — every dimension embeds security-by-design as its foundational concern.

| Dimension | Focus | Absorbed from |
|-----------|-------|---------------|
| 1 — Trust Zone & Authority Architecture | Capability boundaries, trust zones, authority topology, least-privilege decomposition, network segmentation, deployment architecture | Old D1 (Static Architecture) + Security trust boundaries + IAM/Container security |
| 2 — Security Traceability & Agent-Readability | Can you trace who can call what from any entry point? Are capability boundaries visible in naming? Are security invariants documented at module level? | Old D2 (Agent-Readability) + credential scope documentation |
| 3 — Runtime Hazard & Attack Surface | Every hazard framed as "what's the worst thing if this fails?" — privilege escalation paths, injection surfaces, TOCTOU as structural flaws, API auth gates | Old D3 (Runtime Hazards) + API Security & Auth |
| 4 — Security Invariant Bug Hunt | Every bug evaluated against security invariants (can X ever call Y without Z?). Misuse-case-driven analysis. Credential lifecycle patterns, key hygiene. | Old D4 (Bug Hunt) + credential patterns + key hygiene |
| 5 — Defense-in-Depth, Dependencies & Conventions | Multiple independent enforcement layers, dependency trust (pinned hashes, supply chain), naming/file conventions encoding security, audit trails, error handling hygiene | Old D5 (Style) + rate-limiting/CORS + dependency security + defense-in-depth |

---

## Priority Hierarchy

| Priority | Category | What it covers |
|----------|----------|----------------|
| P1 | **Security Correctness** | Active vulnerabilities, privilege escalation paths, broken trust boundaries, credential leaks, hardcoded secrets |
| P2 | **Architectural Security** | Missing capability gates, over-scoped credentials, weak defense-in-depth, undocumented trust boundaries |
| P3 | **Agent-Readability & Security Traceability** | Ambiguous authority topology, unclear capability scope, undocumented security invariants |
| P4 | **Hygiene** | naming, file org, comment quality, dependency freshness |
| P5 | **Observation** | notes, curiosities, no action required |

Output session plans cover P1–P3 only. P4–P5 go to the report as informational.

---

## Finding Format

```markdown
## Finding: <short title>
- **Priority**: P1–P5
- **File**: `path/to/file.ext:line`
- **Dimension**: Trust Zone / Traceability / Runtime Hazard / Bug Hunt / Defense-in-Depth
- **SecurityInvariant**: <the invariant this finding violates>
- **Description**: <clear description>
- **Recommendation**: <actionable fix>
- **Evidence**: <code snippet>
```

---

## Phase 0 — Codebase Orientation

1. Record `$sessionStart`, set agent ID, write PID + heartbeat.
2. Load this file (`architectural-audit.md`) for methodology.
3. Get bird's-eye view: top-level directories, `AGENTS.md`, `docs/Reference/`, fleet topology.
4. Identify key source directories to scan (skip `.git/`, `node_modules/`, `Tasks/Logs/`, `Tasks/Complete/`).
5. **Run AQE topology and quality scan** (non-blocking if bridge unavailable):
   ```powershell
   $aqeScript = "Skills/Workflows/Audit/Invoke-AqeAuditScan.ps1"
   $today = Get-Date -Format "yyyy-MM-dd"
   & $aqeScript -OutputFile "Tasks/Logs/aqe-scan-$today.json" -SkipValidationPipeline -SkipDefectPredict
   ```
   The architectural audit uses AQE's `qe_mincut_analyze` (fleet topology SPOF detection), `qe_coherence_audit` (cross-domain coherence), `quality_assess` (security pillar of the 4-pillar scorecard), and `qe_security_url-validate` (PII/secret scanner). These complement the model-driven architectural judgment with structural analysis that grep cannot provide. Load results in Phase 1 to identify trust boundary weaknesses and in Phase 5 for defense-in-depth gaps.

## Phase 0.5 — Code Security & Correctness Scan

Run the automated pre-scan defined in [`architectural-audit-code-security-scan.md`](architectural-audit-code-security-scan.md) before the model-driven dimensions begin. This phase surfaces implementation-level security hazards (SQL injection, command injection, unsafe casts, unsanitized inputs, silent catch blocks, hardcoded secrets) that model review alone can miss.

1. Launch the scan for the target repo's languages.
2. Load the draft findings into Phase 3 (Runtime Hazard) and Phase 4 (Bug Hunt) for architectural judgment.
3. Do **not** generate session plans from this phase — plans are written in Phase 6 after validation.

---

## Phase 1 — Trust Zone & Authority Architecture

**Security Invariant**: No component should hold a capability it does not need.

For each major module/directory:
- Map capability boundaries — what can each component do? What credentials does it hold?
- Evaluate least-privilege decomposition — could a capability be split into smaller scopes?
- Identify implicit trust relationships — does any component trust network location over tokens?
- Check network segmentation — which overlay networks does each service join? Are ports exposed beyond minimum?
- Verify authorization topology — is there a clear delegation chain from entry point to data access?
- Evaluate deployment architecture — does the deployment order respect capability dependencies?

---

## Phase 2 — Security Traceability & Agent-Readability

**Security Invariant**: Every authority relationship in the system should be discoverable by reading one file.

Per module:
- Entry point clarity — can you tell what it does in 10 seconds? Can you trace which credentials it accesses?
- Capability scope visibility — are credential scopes documented at module boundaries?
- Type explicitness — typed signatures or untyped dictionaries? Do types encode security boundaries?
- Naming consistency — do names reflect the capability model? (e.g., `ReadKey` vs `WriteKey`)
- Comment quality — stale? restating obvious? missing on non-obvious logic? Are security invariants documented?
- Navigation — from entry point, find any feature in under 3 hops? Can you find all callers of a credential endpoint?
- Test structure — behavior-named, co-located? Do tests verify negative cases (no auth = 401)?

---

## Phase 3 — Runtime Hazard & Attack Surface

**Security Invariant**: Every failure mode should be evaluated for privilege escalation potential.

Scan for:
- **Privilege escalation paths**: shared mutable state without locks that could let one component access another's data, timer callbacks that inherit elevated privileges
- **Injection surfaces**: unsanitized shell/sql/path input, parameter injection in credential endpoints
- **TOCTOU as structural flaws**: check-then-act without locking, file existence check then separate open
- **API auth gates**: endpoints missing auth middleware, auth bypass via internal IP or specific headers
- **Error handling**: empty catch blocks, discarded errors, secrets in error messages, missing `finally` blocks
- **Resource leaks**: unclosed file/stream/connection/HTTP clients, per-request client creation
- **Idempotency gaps**: non-idempotent create-if-not-exists, assumption of single-caller semantics

---

## Phase 4 — Security Invariant Bug Hunt

**Security Invariant**: No code path should allow X to call Y without Z's authorization.

Read code file-by-file for:
- Null/undefined safety in credential-handling paths
- Logic errors that bypass security checks (wrong operator, inverted condition, off-by-one)
- Edge cases in auth logic (empty token treated as valid, null inputs, boundary values)
- Credential lifecycle patterns — hardcoded credentials, unsanitized credential input, credential caching without expiry
- Key hygiene — keys shared across services, keys with excessive scope, missing key rotation
- API misuse — wrong argument order in security-sensitive calls, unused return values from auth functions
- Security violations — hardcoded secrets, unsanitized shell/sql/path input, missing auth checks
- Type safety — implicit casts losing data in security-sensitive paths

---

## Phase 5 — Defense-in-Depth, Dependencies & Conventions

**Security Invariant**: Compromising one security layer should not compromise the next.

Per module:
- **Defense-in-depth**: Are there multiple independent enforcement layers? Does credential hydration require both AWS SM access AND Docker Swarm secret mount?
- **Dependency trust**: Are dependencies pinned to specific hashes (not mutable tags)? Supply chain verifiable?
- **Cryptography practices**: No custom crypto, proper TLS verification, modern algorithms
- **Audit trails**: Are audit trails append-only and tamper-evident? Do they avoid leaking secrets?
- **Error handling hygiene**: Error messages without sensitive info, proper use of `catch` blocks
- **Naming/file conventions**: Do file names encode security boundaries? Are conventions consistent?
- **Code quality**: dead code, test structure, idiom consistency

---

## Phase 5.5 — Security Verification & Unit Test Build-Out

**Security Invariant**: Every security-critical behavior must be reproducible by an automated test, especially the failure cases.

This phase is the final security pass before consolidation. Its purpose is to convert the architectural findings into a durable test harness so that the same vulnerability cannot re-enter the codebase undetected. Perform the following steps for the target repo:

### Step 1 — Map security-critical surfaces to tests
For each P1–P3 finding from Phases 1–5, identify the specific function, route, module, or configuration file that enforces the violated invariant. Then answer:
- Is there an existing unit or integration test that exercises the secure path?
- Is there a negative test that proves the insecure path is rejected (e.g., no token → 401, wrong role → 403, malformed input → 400/422)?
- Is there a property or fuzz test that exercises boundary values?
- Does the test use real secrets, or does it use mocks/fixtures/isolated test credentials?

### Step 2 — Score test coverage by security layer
| Layer | What to check | Missing-coverage finding |
|-------|---------------|-------------------------|
| **Authentication** | Tests for missing/invalid/expired tokens, token format validation, brute-force throttling | P3 if no negative auth tests exist |
| **Authorization** | Role/claim/capability checks, ownership checks, admin gates | P2 if an auth gate has no test |
| **Input validation** | Length, type, allow-list, schema, path canonicalization, SQL/NoSQL/command injection payloads | P2 for each untested input surface |
| **Secrets handling** | No secret leakage in logs/errors, `SecureString`/env isolation, rotation fallback | P2 if secret-handling code has no tests |
| **Cryptography** | TLS verification, no custom crypto, key derivation, hash comparisons | P2 if crypto code is untested |
| **Error handling** | Safe error paths do not leak PII/secrets, fail-closed behavior | P3 if error tests are missing |
| **Audit logging** | Append-only log entries, tamper evidence, no secret logging | P3 if audit path is untested |

### Step 3 — Build out unit tests thoroughly
For every row in the coverage score with a gap:
1. Write a failing or missing test that reproduces the insecure condition. Prefer fast unit tests; use integration tests only when the boundary (network, container, real secret store) is required.
2. Name the test after the behavior it proves, e.g., `Invoke-AuthGate - rejects expired token`, `Expand-Archive - blocks path traversal in archive names`, `UpdateCredential - does not write secret to log`.
3. Include at least one positive test (secure path succeeds), one negative test (insecure path is rejected), and one boundary test (null, empty, maximum length, malformed structure).
4. Use the repo's test framework (Pester, vitest, pytest, Jest, Go test) and follow existing conventions for mocks, fixtures, and tags.
5. If the finding is in a new or refactored module, generate a session plan with namespace `architectural-tests` and title `Build unit tests for <module> security invariants`. The plan must list every test to be added as an explicit task.
6. Do **not** implement the tests in this audit phase. Record the test requirements as findings and let the Coder session build them.

### Step 4 — Emit the test-build plan
Consolidate the unit-test gaps into one or more `architectural-tests` session plans. Each plan:
- References the P1–P3 finding it guards against in `**DependsOn**`.
- Includes the failing/missing test cases as acceptance criteria.
- Verifies the fix with the same tests it adds.
- Emphasizes that building out the tests thoroughly is a first-class deliverable, not an afterthought.

Output session plans from this phase only for P1–P3 gaps. P4–P5 coverage observations go into the report as informational.

---

## Cross-Dimension Security Invariants

These invariants span all five dimensions and should guide every finding:

1. **No implicit trust** — every cross-boundary interaction requires explicit capability delegation. Trusting network location, hostname, or container name over authentication tokens is a finding.
2. **Least privilege** — no component holds a credential or capability it does not need. Every IAM policy, secret bundle, and API token should be scoped to minimum necessary.
3. **Defense in depth** — compromising any single protection layer (network, credential store, application code) should not grant access to the underlying resource. Two independent enforcement mechanisms must fail before access is granted.
4. **Security traceability** — from any entry point, an auditor should be able to trace the full authority chain (who can call what, with which credentials) in under 3 hops.
5. **Fail securely** — authentication or authorization failures must default to denial. Missing credentials, expired tokens, and unrecognized callers all produce the same outcome: access denied with minimal information leakage.
6. **No capability without documentation** — every credential, API key, secret bundle, and IAM policy must have a documented scope, owner, and rotation mechanism. Undocumented capabilities are unmanaged attack surface.

---

## Phase 6 — Consolidation & Plan Generation

1. **Deduplicate** findings across all 5 dimensions.
2. **Prioritize** by hierarchy: P1 > P2 > P3 > P4 > P5.
3. **Write summary report** to `Tasks/Logs/Audit/architectural/<date>-architectural-report.md`:
   - Executive summary (top 3-5 findings, overall health)
   - Findings by priority (P1–P5)
   - Findings by file
   - Cross-references to generated session plans
4. **Write session plans** to `Tasks/Code/` for P1–P3 findings only:
   - Group related findings into connascent batches (2–5 tasks per plan)
   - Prefix with `architectural-` namespace (use `architectural-tests` for Phase 5.5 unit-test build-out plans)
   - Follow `session-plan-format.md`
   - **No default cap — emit one plan per distinct verified finding.** The historical "Max 10 plans per invocation" cap was removed 2026-07-28 by user direction: audits print comprehensively by default. Group genuinely-related findings into one plan only when they share a remediation; never suppress findings to hit a count.
5. Run Complete CC per workflow-primitives.md steps 1–10. Commit report + plans, push.

---

## Cross-References

- `Skills/Auditor/SKILL.md` — Audit mode parent
- `Skills/Auditor/alignment-audit.md` — sibling: Alignment Audit (9-domain drift survey)
- `Skills/Archive/workflow-audit-deprecated-security-audit.md` — **Deprecated** — structural security concerns absorbed into this document
- `Skills/Create/Skill-Authoring/workflow-primitives.md` — shared primitives
- `Skills/Workflows/Shared/session-plan-format.md` — plan format for generated sessions
- `Skills/Orchestrator/archreview.md` — **DEPRECATED** precursor (retained as reference)

## Changelog
- 2026-06-19: Created as merged Architectural Audit domain within Audit mode (replaces standalone ArchReview)
- 2026-06-20: First full execution. 27 findings across 6 dimensions, 8 session plans generated.
- 2026-07-07: Security-first refactor. Replaced 6 dimensions (security as D6) with 5 security-first dimensions. Absorbed structural security concerns from deprecated Security Audit track and deprecated alignment-audit-domain-12-security.md.
