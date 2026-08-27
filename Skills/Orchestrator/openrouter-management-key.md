# Skill: OpenRouter Management API Key

**Purpose**: Guide agents through using the OpenRouter Management API key (`OPENROUTER_SETUP_KEY`) for administrative operations — listing/creating workspaces, creating/updating/assigning guardrails, and managing API keys.

**Prerequisites**: AWS SSO session `interclaw` must be active (`aws sso login --sso-session interclaw`). The key lives in AWS SM at `Interclaw/FRAD/Provisioning` under `OPENROUTER_SETUP_KEY`.

**Recognition**: Triggered when a user needs to set guardrails, manage workspaces, rotate/create API keys, or perform other OpenRouter administrative tasks.

---

## Key Facts

| Property | Value |
|----------|-------|
| **Key name** | `OPENROUTER_SETUP_KEY` |
| **AWS SM location** | `Interclaw/FRAD/Provisioning` |
| **Key prefix** | `sk-or-v1-*` (same prefix as regular API keys) |
| **Auth header** | `Authorization: Bearer <key>` |
| **API base** | `https://openrouter.ai/api/v1` |
| **Key type** | Management key — required for all admin endpoints |

**Important**: Management keys cannot be used for inference (`POST /chat/completions`). They are exclusively for administrative operations.

---

## Retrieving the Key

```powershell
$env:AWS_PROFILE = "interclaw"
$env:AWS_DEFAULT_REGION = "ca-central-1"
$secret = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --query "SecretString" --output text
$setupKey = ($secret | ConvertFrom-Json).OPENROUTER_SETUP_KEY
```

---

## API Endpoints

### Workspaces

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/v1/workspaces` | List all workspaces |
| `PATCH` | `/api/v1/workspaces/{id}` | Update workspace settings |

### Guardrails

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/v1/guardrails` | List all guardrails (filter by `?workspace_id=`) |
| `POST` | `/api/v1/guardrails` | Create a guardrail |
| `PATCH` | `/api/v1/guardrails/{id}` | Update a guardrail |
| `DELETE` | `/api/v1/guardrails/{id}` | Delete a guardrail |
| `GET` | `/api/v1/guardrails/{id}/assignments/keys` | List API keys assigned to a guardrail |
| `POST` | `/api/v1/guardrails/{id}/assignments/keys` | Assign API keys to a guardrail |

### API Keys

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `GET` | `/api/v1/keys` | List all API keys |
| `POST` | `/api/v1/keys` | Create a new API key |
| `PATCH` | `/api/v1/keys/{hash}` | Update a key (name, limit, disable) |
| `DELETE` | `/api/v1/keys/{hash}` | Delete a key |

---

## Guardrail Schema

```json
{
  "name": "Guardrail Name",
  "description": "Optional description",
  "limit_usd": 50,
  "reset_interval": "daily|weekly|monthly",
  "allowed_models": null,
  "allowed_providers": null,
  "ignored_models": null,
  "ignored_providers": null,
  "enforce_zdr": true,
  "enforce_zdr_anthropic": true,
  "enforce_zdr_openai": true,
  "enforce_zdr_google": true,
  "enforce_zdr_other": true,
  "content_filter_builtins": [
    { "slug": "credit-card", "action": "redact" },
    { "slug": "ssn", "action": "redact" },
    { "slug": "ip-address", "action": "redact" },
    { "slug": "address", "action": "redact" },
    { "slug": "email", "action": "redact" },
    { "slug": "phone", "action": "redact" },
    { "slug": "person-name", "action": "redact" },
    { "slug": "regex-prompt-injection", "action": "block" }
  ],
  "content_filters": null,
  "workspace_id": "UUID"
}
```

Available builtin slugs: `email`, `phone`, `ssn`, `credit-card`, `ip-address`, `person-name`, `address`, `regex-prompt-injection`.

---

## What Worked

### Creating guardrails

```powershell
$body = @{
    name = "Daily Limit"
    limit_usd = 5
    reset_interval = "daily"
    enforce_zdr = $true
    content_filter_builtins = @(
        @{ slug = "credit-card"; action = "redact" }
        @{ slug = "regex-prompt-injection"; action = "block" }
    )
} | ConvertTo-Json

$result = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/guardrails" `
    -Headers @{ Authorization = "Bearer $setupKey"; "Content-Type" = "application/json" } `
    -Method Post -Body $body
```

**Caveat**: When using `ConvertTo-Json` in PowerShell, any `$` in string values (like `"$5"`) will be interpreted as a variable reference. Use single-quoted JSON strings or escape the `$` to avoid corruption.

### Assigning keys to a guardrail

The body must use `key_hashes` (plural, array), not `key_hash`:

```powershell
$body = '{"key_hashes":["hash1","hash2","hash3"]}'
$result = curl.exe -s -X POST "https://openrouter.ai/api/v1/guardrails/{guardrail_id}/assignments/keys" `
    -H "Authorization: Bearer $setupKey" `
    -H "Content-Type: application/json" `
    -d $body
# Response: {"assigned_count":3}
```

**Important**: A key can only be assigned to ONE guardrail. Assigning a second guardrail replaces the first. Verify with:

```powershell
curl.exe -s "https://openrouter.ai/api/v1/guardrails/{guardrail_id}/assignments/keys" `
    -H "Authorization: Bearer $setupKey"
```

---

## What Didn't Work

| Attempt | Result | Why |
|---------|--------|-----|
| `PATCH /api/v1/keys/{hash}` with `guardrail_id` | `400 Bad Request` | Key update endpoint does not accept `guardrail_id` |
| `POST /api/v1/guardrails/{id}/assignments/keys` with `{"key_hash":"..."}` | `400 ZodError` | Field must be `key_hashes` (plural, array) |
| `POST /api/v1/guardrails/{id}/assignments/keys` with `{"hash":"..."}` | `400 ZodError` | Same — wrong field name |
| Assigning two guardrails to the same key sequentially | Second replaces first | Keys support only ONE guardrail assignment |

---

## Complete Workflow: Setting Default Guardrails on a Workspace

```powershell
# 1. Auth
$env:AWS_PROFILE = "interclaw"; $env:AWS_DEFAULT_REGION = "ca-central-1"
$secret = aws secretsmanager get-secret-value --secret-id "Interclaw/FRAD/Provisioning" --query "SecretString" --output text
$setupKey = ($secret | ConvertFrom-Json).OPENROUTER_SETUP_KEY
$headers = @{ Authorization = "Bearer $setupKey"; "Content-Type" = "application/json" }

# 2. List workspaces
$ws = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/workspaces" -Headers $headers
$wsId = $ws.data[0].id  # "Default Workspace"

# 3. Create a guardrail
$body = '{"name":"Monthly Limit","description":"Default guardrail","workspace_id":"' + $wsId + '","limit_usd":50,"reset_interval":"monthly","enforce_zdr":true,"content_filter_builtins":[{"slug":"regex-prompt-injection","action":"block"},{"slug":"credit-card","action":"redact"},{"slug":"ssn","action":"redact"},{"slug":"ip-address","action":"redact"},{"slug":"address","action":"redact"},{"slug":"email","action":"redact"},{"slug":"phone","action":"redact"},{"slug":"person-name","action":"redact"}]}'
$guardrail = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/guardrails" -Headers $headers -Method Post -Body $body
$gid = $guardrail.data.id

# 4. List keys
$keys = Invoke-RestMethod -Uri "https://openrouter.ai/api/v1/keys" -Headers $headers -Method Get
$hashes = $keys.data.hash

# 5. Assign guardrail to all keys
$assignBody = '{"key_hashes":["' + ($hashes -join '","') + '"]}'
curl.exe -s -X POST "https://openrouter.ai/api/v1/guardrails/$gid/assignments/keys" -H "Authorization: Bearer $setupKey" -H "Content-Type: application/json" -d $assignBody

# 6. Verify
curl.exe -s "https://openrouter.ai/api/v1/guardrails/$gid/assignments/keys" -H "Authorization: Bearer $setupKey"
```

---

### Lessons Learned — 2026-06-14

- **Management keys look like regular API keys** (`sk-or-v1-*`). The only way to distinguish them is by trying a management endpoint — regular keys return 401, management keys work.
- **Key-level limits vs guardrails**: API keys have their own `limit` + `limit_reset` fields. A guardrail assigned to a key adds additional constraints on top. Both are enforced independently.
- **One guardrail per key limit**: Only one guardrail can be assigned to a key. To enforce both daily and monthly budgets, you need to pick one guardrail or set the limit at the key level instead.
- **curl.exe vs Invoke-RestMethod**: `Invoke-RestMethod` in PowerShell doesn't easily expose response bodies on errors. Use `curl.exe -s -w "%{http_code}"` to get both the status code and response body.
- **PowerShell string interpolation**: `$` in JSON strings inside double-quoted strings will be interpreted as variable expansion. Always use single-quoted JSON or explicit string concatenation.
- **ZDR enforcement via `enforce_zdr`**: The deprecated `enforce_zdr` field auto-populates `enforce_zdr_anthropic`, `enforce_zdr_openai`, `enforce_zdr_google`, and `enforce_zdr_other` if they aren't explicitly set.
- **PII redaction actions**: Builtin filters support `redact`, `block`, and `flag` actions. The `flag` action is only supported for `regex-prompt-injection`. PII slugs only accept `block` or `redact`.
