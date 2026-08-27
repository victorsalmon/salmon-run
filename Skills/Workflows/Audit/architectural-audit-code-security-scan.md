# Architectural Audit — Phase 0.5 Code Security & Correctness Scan

**Part of**: Architectural Audit (`Skills/Workflows/Audit/architectural-audit.md`)
**Purpose**: Surface implementation-level security bugs and code-correctness hazards before the model-driven dimensions begin. This is a pre-filter, not a substitute for Phases 1–5.
**Output**: A list of draft findings (severity `high` until validated by the model in Phases 3 or 4) that must be logged to the audit trail.

---

## Security Invariant

Code must not trust or execute attacker-controlled data without validation, type safety, and explicit authorization.

---

## Patterns to Flag

For each source language in the target repo, scan for the following categories. Do not attempt to fix — only document, classify, and pass to Phase 3 (Runtime Hazard) or Phase 4 (Bug Hunt) for model judgment.

### 1. SQL / NoSQL / ORM injection

- Raw `sql` tagged-template literals with embedded `${...}` or `+` concatenation in TypeScript/JavaScript (Drizzle, `pg`, Knex, etc.).
  - Safe alternatives: `inArray()`, `eq()`, `sql` with bound parameters.
- String concatenation inside SQL or NoSQL query strings.
- Unsanitized user input reaching a database query builder (e.g. `where({ id: req.query.id })`).
- PowerShell `Invoke-Sqlcmd` or `SqlCommand` with `-Query` built from variables or user input without parameter objects.

### 2. Command, shell, and path injection

- `exec`, `execSync`, `Start-Process`, `Invoke-Expression`, `iex`, `eval`, `new Function()` with user-controlled strings.
- File paths built from user input without `Join-Path`, `Resolve-Path`, `Test-Path`, or allow-list validation.
- Archive, delete, or write operations (`Expand-Archive`, `Remove-Item -Recurse`, `Out-File`) with paths derived from parameters.
- Shell command construction via string concatenation.

### 3. Unsafe type and parse assumptions

- `as any`, `as any[]`, `as unknown as` in security-sensitive paths (auth, SQL, serialization, secrets handling).
- `parseInt` / `parseFloat` on request parameters without `Number.isNaN` or `isNaN` validation.
- PowerShell casts like `[int]$userInput` without `[ValidateRange()]`, `[ValidatePattern()]`, or `try/catch`.
- `JSON.parse` of untrusted data without schema validation or `try/catch`.
- `ConvertFrom-Json` of untrusted data without `-ErrorAction Stop` and validation.

### 4. Unsanitized inputs

- Request bodies, query strings, headers, file names, or MIME types used without length, type, charset, or allow-list validation.
- `c.req.json()`, `req.body`, `$args`, `$env:`, `Read-Host` values trusted implicitly.
- Missing `try/catch` around `c.req.json()`, `await c.req.json()`, or `ConvertFrom-Json`.
- Path traversal sequences (`../`, `..\`) accepted in user input before path canonicalization.

### 5. Empty or silent error handling

- `.catch(() => {})` or `.catch((e) => { /* no throw */ })` in JavaScript/TypeScript.
- `catch { }`, `catch { Write-Host $_ }`, or `catch { <# ignore #> }` without re-throw or structured logging.
- `try { ... } finally { ... }` with no `catch`.
- Empty catch blocks in credential, secret, or authorization paths.
- `On Error Resume Next` equivalents in any language.

### 6. Hardcoded secrets and credentials

- `AKIA...` AWS access keys, secret tokens, private keys, or connection strings with passwords in source.
- `ConvertTo-SecureString` with hardcoded keys.
- `password =`, `token =`, `apiKey =`, `secret =` in non-config files.
- JWT or session secrets embedded in code.

### 7. Unsafe web and serialization

- `innerHTML` or `dangerouslySetInnerHTML` with dynamic or user-controlled content.
- `eval`, `setTimeout(string)`, `setInterval(string)`, `new Function(string)`.
- DOM `insertAdjacentHTML` with un-sanitized input.
- Inline config objects in HTML/JS that leak secrets or backend state (`window.__UH_CONFIG__`, `window.__CONFIG__`).

### 8. Authorization and auth-bypass patterns

- Endpoints or functions with no auth gate.
- `c.get('auth')` null checks missing or returning `next()` for missing auth in non-public routes.
- `if (!auth) { await next(); return; }` or equivalent bypass.
- Role checks based on client-side claims rather than server-side verified groups.
- `c.req.header('x-admin-key')` without constant-time comparison.

### 9. Insecure deserialization, reflection, and unsafe parsing

- `JSON.parse` / `ConvertFrom-Json` of untrusted data without schema validation or error handling.
- `eval`, `new Function`, `Invoke-Expression` / `iex` on parsed or remote data.
- Unsafe `pickle.loads`, `yaml.load`, `unmarshal`, or `ObjectInputStream` with user input.
- Reflection or dynamic invocation (`Get-Command`, `Invoke-Command -ScriptBlock`, `CallByName`) driven by user-controlled strings.
- Prototype pollution via unchecked recursive object merge.
- XML parsing with DTD/XXE enabled (`XmlDocument`, `loadxml`, etc.).

### 10. Side-channel, logging, and secret-leakage patterns

- Secrets, tokens, or PII written to stdout, logs, or error messages.
- Verbose exception handlers that return stack traces, query strings, or environment details to clients.
- Timing-sensitive comparisons (`==` on passwords, tokens, HMACs) instead of constant-time helpers.
- Cache or session stores shared across tenants without isolation.
- Predictable IDs, sequential identifiers, or weak randomness (`Math.random`, `Get-Random` used for tokens).

### 11. Reproducer-test requirement for each validated P1–P2 finding

For every finding promoted to P1 or P2 in Phases 3 or 4, the audit must record the **test that would have caught it**:
- The expected failing assertion (e.g., `should return 401`, `should throw on path traversal`).
- The input fixture or payload that reproduces the flaw.
- Whether the test belongs in an existing test file or a new `architectural-tests` plan.

This requirement feeds directly into `architectural-audit.md` Phase 5.5 — Build out unit tests thoroughly.

---

## Scan Execution

Use the repo's language-appropriate tooling. Below are example `rg` (ripgrep) invocations for TypeScript and PowerShell. Replace paths and globs as needed for the target repo.

### TypeScript / JavaScript

```powershell
# Raw sql`...` with embedded ${} variables
rg 'sql\s*`[^`]*\$\{' backend/src -g '!*.{test,spec}.*'

# as any casts in source
rg '\bas any\b' backend/src

# Empty catch blocks
rg '\.catch\s*\(\s*\(\s*\)\s*=>\s*\{\s*\}\s*\)' backend/src

# eval / new Function / setTimeout string
rg '\beval\s*\(|\bnew\s+Function\s*\(|\bsetTimeout\s*\(\s*[\"\`]' backend/src

# parseInt / parseFloat without isNaN (manual review of matches)
rg '\bparse(Int|Float)\s*\(' backend/src
```

### PowerShell

```powershell
# Invoke-Expression / iex / Start-Process with variable
rg 'Invoke-Expression|iex\b|Start-Process\s+.*\$' Skills -g '*.ps*'

# Empty catch blocks
rg 'catch\s*\{\s*\}' Skills -g '*.ps*'

# Write-Host without logging in catch
rg 'catch\s*\{[^}]*Write-Host[^}]*\}' Skills -g '*.ps*'

# Hardcoded secrets (heuristic)
rg '(?i)(password|token|api[_-]?key|secret)\s*=\s*["\'][^"\']{8,}' Skills -g '*.ps*'
```

---

## Logging Findings

For every candidate, produce a draft finding with:

```markdown
## Finding: <pattern> in <file>
- **Priority**: high (pending model validation)
- **File**: `path/to/file:line`
- **Dimension**: Code Security & Correctness (Phase 0.5)
- **SecurityInvariant**: Code must not trust or execute attacker-controlled data without validation.
- **Description**: <what the scan found>
- **Recommendation**: <preliminary remediation; model refines in Phase 3/4>
- **Evidence**: <one-line snippet or rg command output>
```

Feed every finding into the later model-driven phases. The scan itself does not produce session plans; session plans are generated in Phase 6.

---

## Changelog

- 2026-08-07: Extracted from `architectural-audit.md` to keep the main workflow concise while adding an explicit code-correctness and injection-surface pre-scan.
