# Skill: create-mcp

**Purpose**: Build a new MCP-over-SSE server for the ORCHESTRATOR fleet, integrating it end-to-end through the existing service pattern: Express + SDK, Docker, secret bundle, compose entry, image build, and opencode MCP registration.

**Trigger**: User says "create an MCP server", "add an MCP tool", "build a fleet service", "make X available as MCP tools", or similar. Also use when adding new REST endpoints to an existing MCP server.

---

## What This Produces

A fleet service that:
- Runs as a Docker Swarm service sidecar
- Exposes MCP tool discovery over SSE at `/mcp/sse`
- Also serves REST API endpoints (health, credentials, routes, domain-specific)
- Uses Express + `@modelcontextprotocol/sdk`
- Receives secrets via a Docker Swarm secret bundle
- Is authenticated through `fleet-auth.cjs` middleware
- Is discoverable by all opencode agents via MCP

## Prerequisites

- `Infrastructure/port-registry.json` — pick the next available port in `mcp_sidecar_internal` range (21000-21999)
- `SalmonRun.Constants` module — for `Get-ServicePort` resolution
- `SalmonRun.Deploy` module — for compose generation
- `SalmonRun.Secrets` module — for bundle management
- `SalmonRun.Images` module — for image build
- Existing reference services to copy from (`is-bookkeeping`, `mcp_aqe`; the former `mcp_web` reference was retired 2026-08-22)

## Integration Points (8 Steps)

### 1. Server Code (`Infrastructure/<name>-mcp-server.js`)

Place a single ESM file at `Infrastructure/`. Template:

```js
import express from 'express';
import rateLimit from 'express-rate-limit';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { SSEServerTransport } from '@modelcontextprotocol/sdk/server/sse.js';
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { mkdirSync, appendFileSync } from 'fs';
import { join } from 'path';

const PORT = process.env.PORT || 210XX;
const DEFAULT_TIMEOUT = parseInt(process.env.REQUEST_TIMEOUT || '30000', 10);
const AUDIT_DIR = process.env.AUDIT_DIR || '/var/log/mcp-audit';
const START_TIME = Date.now();
const app = express();
app.use(express.json());

// Rate limiting — mandatory for services making external API calls
const globalLimiter = rateLimit({ windowMs: 60000, max: 60, standardHeaders: true, legacyHeaders: false });
app.use(globalLimiter);

const { createFleetAuth } = require('./auth/fleet-auth.cjs');
app.use(createFleetAuth());

// CORS
app.use((req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, PATCH, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(204).end();
  next();
});

// Request logging + audit trail
mkdirSync(AUDIT_DIR, { recursive: true });
function logAudit(event, meta = {}) {
  const entry = JSON.stringify({ timestamp: new Date().toISOString(), event, ...meta });
  console.log(entry);
  try { appendFileSync(join(AUDIT_DIR, 'audit.jsonl'), entry + '\n'); } catch {}
}

app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => logAudit('api_request', { method: req.method, path: req.path, status: res.statusCode, durationMs: Date.now() - start }));
  next();
});

// fetch with timeout — use for all external API calls
async function fetchWithTimeout(url, options = {}, timeoutMs = DEFAULT_TIMEOUT) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
}

// Retry with exponential backoff — use for rate-limited external APIs
async function retryWithBackoff(fn, maxRetries = 3, baseDelay = 500) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt === maxRetries) throw err;
      const isRetryable = err.status === 429 || err.status >= 500 || err.name === 'AbortError' || err.type === 'system';
      if (!isRetryable) throw err;
      const delay = baseDelay * Math.pow(2, attempt - 1) + Math.random() * 200;
      logAudit('retry', { attempt, maxRetries, delayMs: Math.round(delay), error: err.message });
      await new Promise(r => setTimeout(r, delay));
    }
  }
}

// Environment-aware secret reader (file mount via Docker secret > env var)
function readSecret(name, envVar) {
  const filePath = process.env[name + '_FILE'];
  if (filePath) try { return require('fs').readFileSync(filePath, 'utf8').trim(); } catch {}
  return process.env[envVar] || '';
}

function healthResponse() {
  return { status: 'ok', service: '<name>', version: '1.0.0', uptime: Math.floor((Date.now() - START_TIME) / 1000) };
}

// Required fleet endpoints
app.get('/health', (_req, res) => res.json(healthResponse()));
app.get('/api/health', (_req, res) => res.json(healthResponse()));
app.get('/api/ready', async (_req, res) => res.json({ ready: true }));
app.get('/api/routes', (_req, res) => res.json({ routes: [ /* list all endpoints */ ] }));
app.get('/api/version', (_req, res) => res.json({ name: '<name>', version: '1.0.0' }));

// Domain-specific endpoints (add your REST API here)
app.post('/api/<name>/action', async (req, res) => { /* ... */ });

// MCP tool definitions
const MCP_TOOLS = [
  {
    name: '<tool_name>',
    description: '...',
    inputSchema: {
      type: 'object',
      properties: { /* ... */ },
      required: [],
    },
  },
];

// MCP tool handlers
const toolHandlers = {
  '<tool_name>': async (args) => {
    const result = await doSomething(args);
    return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
  },
};

// SSE transport
const sseTransports = {};

app.get('/mcp/sse', async (req, res) => {
  const server = new Server(
    { name: '<name>-sse', version: '1.0' },
    { capabilities: { tools: {} } }
  );
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: MCP_TOOLS.map(t => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
  }));
  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const handler = toolHandlers[request.params.name];
    if (!handler) throw new Error(`Unknown tool: ${request.params.name}`);
    return await handler(request.params.arguments || {});
  });
  const transport = new SSEServerTransport('/mcp/message', res);
  sseTransports[transport.sessionId] = transport;
  res.on('close', () => delete sseTransports[transport.sessionId]);
  await server.connect(transport);
});

app.post('/mcp/message', async (req, res) => {
  const transport = sseTransports[req.query.sessionId];
  if (transport) await transport.handlePostMessage(req, res);
  else res.status(400).json({ error: 'No session found' });
});

// Per-agent rate limiting (for MCP servers making external API calls)
const MAX_REQUESTS_PER_AGENT = 30;
const WINDOW_MS = 60000;
const perAgentBuckets = new Map();
function checkPerAgentLimit(agentId) {
  const now = Date.now();
  const bucket = perAgentBuckets.get(agentId) || { count: 0, resetAt: now + WINDOW_MS };
  if (now > bucket.resetAt) { bucket.count = 0; bucket.resetAt = now + WINDOW_MS; }
  bucket.count++;
  perAgentBuckets.set(agentId, bucket);
  return bucket.count <= MAX_REQUESTS_PER_AGENT;
}

// Startup logging — mask key status to boolean only
app.listen(PORT, () => {
  console.log(`<name> MCP listening on port ${PORT}`);
  logAudit('startup', { service: '<name>', port: PORT });
});
```

### 2. Dockerfile (`Infrastructure/<name>.Dockerfile`)

Pattern from a retired reference Dockerfile (formerly `Infrastructure/mcp_web.Dockerfile`, removed 2026-08-22; see `Skills/DevOps/Fleet/images/SKILL.md` for live build entries):

```dockerfile
FROM node:20-alpine@sha256:<pinned-digest>

WORKDIR /app

RUN apk add --no-cache curl && \
    adduser -D -u 1001 ORCHESTRATOR

RUN npm install @modelcontextprotocol/sdk express

COPY Infrastructure/auth/ /app/auth/
COPY Infrastructure/<name>-mcp-server.js /app/
COPY Infrastructure/<name>/ /app/<name>/   # any additional modules

RUN chown -R ORCHESTRATOR:ORCHESTRATOR /app

USER ORCHESTRATOR

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=15s \
    CMD curl -sf http://localhost:210XX/health || exit 1

EXPOSE 210XX
CMD ["node", "/app/<name>-mcp-server.js"]
```

If the service needs an entrypoint script to hydrate secrets from a bundle (see step 3), use `ENTRYPOINT ["/bin/sh", "/home/node/app/entrypoint.sh"]` instead of `CMD`, and create `Infrastructure/entrypoint-<name>.sh`.

### 3. Secret Bundle

If the service needs API keys or credentials:

**a. Bundle manifest** — Add to `SalmonRun.Secrets/Private/bundle-manifest.ps1`:

```powershell
<Name> = @{
    BundleName = "<name>_secrets_bundle"
    Suffix     = "<name>_secrets_bundle"
    Required   = @()
    Optional   = @('my_api_key', 'my_other_key')
    EnvMap     = @{
        'my_api_key'  = 'MY_API_KEY'
        'my_other_key' = 'MY_OTHER_KEY'
    }
    SourceKeys  = @('MY_API_KEY', 'MY_OTHER_KEY')
}
```

**b. Fleet API tokens** — Add a token entry in the same manifest's `ServiceTokens`:

```powershell
FLEET_API_TOKEN_<NAME> = @{
    BoundServices = @('<name>')
    Audience      = '<name>'
}
```

**c. Publish function** — Create `SalmonRun.Secrets/Public/Publish-<Name>Secrets.ps1` that reads source env vars and builds the bundle JSON.

**d. API base URL configuration** — For any external API the server calls, read the base URL from an env var with a sensible default. Never hardcode API URLs in function bodies:

```js
// At top of server file:
const MY_API_BASE_URL = process.env.MY_API_BASE_URL || 'https://api.example.com/v1';

// Then in call functions:
const resp = await fetchWithTimeout(`${MY_API_BASE_URL}/endpoint`, { ... });
```

This pattern enables mock-server injection during testing and graceful API version upgrades without code changes.

**e. Entrypoint hydration** — If the server is pure Node and reads `process.env` directly, no script needed. If it needs the shell to export vars first, create `Infrastructure/entrypoint-<name>.sh`:

```sh
BUNDLE_PATH="/run/secrets/<name>_secrets_bundle"
if [ -f "$BUNDLE_PATH" ]; then
    eval $(node -e "
        const b = JSON.parse(fs.readFileSync('$BUNDLE_PATH', 'utf8'));
        const envMap = { my_api_key: 'MY_API_KEY', my_other_key: 'MY_OTHER_KEY' };
        for (const [k, v] of Object.entries(b)) {
            const envName = envMap[k] || k;
            if (v && typeof v === 'string' && v.trim())
                console.log('export ' + envName + '=' + JSON.stringify(v.trim()));
        }
    ")
fi
exec node /app/<name>-mcp-server.js
```

### 4. Image Build Function

Create `SalmonRun.Images/Public/Invoke-<Name>ImageBuild.ps1` — copy the pattern from `Invoke-TempoImageBuild.ps1`:

- Parameter: `$TargetDir`
- Dockerfile path: `Join-Path $TargetDir "Infrastructure" "<name>.Dockerfile"`
- Image tag: `<name>:local`
- Source-hash label: `org.interclaw.<name>.source-hash`
- Build: `docker build -f $DockerfilePath -t "<name>:local" --label "org.interclaw.<name>.source-hash=$SourceHash" .`

Then wire into `Start-ParallelImageBuild.ps1`.

### 5. Compose Entry

Add to `SalmonRun.Deploy/Public/New-FleetCompose.ps1` — gated by a feature flag variable like `$Install<Name>`:

```powershell
if ($Install<Name> -eq "true") {
    $Port = Get-ServicePort -Service "<name>" -Type "internal"
    $Service = [ordered]@{
        image       = "<name>:local"
        hostname    = "${ProjectCode}-<name>"
        dns         = @("8.8.8.8", "1.1.1.1")
        networks    = @((Get-NetworkNames).ServiceNet)
        deploy      = [ordered]@{ resources = [ordered]@{...}; restart_policy = [ordered]@{...} }
        healthcheck = [ordered]@{ test = @("CMD", "curl", "-sf", "http://localhost:${Port}/health"); ... }
        ports       = @("127.0.0.1:${Port}:${Port}")
        secrets     = @(
            @{ source = $BundleName; target = "<name>_secrets_bundle" }
            @{ source = "FLEET_API_TOKEN_<NAME>"; target = "fleet_api_token" }
            @{ source = "FLEET_API_TOKEN_MONITOR"; target = "fleet_monitor_token" }
        )
        cap_drop    = @("ALL")
        security_opt = @("no-new-privileges:true")
    }
    $Compose.services["<name>"] = $Service
    $Compose.volumes["<name>_data"] = $null
}
```

Add the feature flag to the `deploy.ps1` configuration parameters so it flows through `$FleetFeatureFlags`.

### 6. Port Registry

Add an entry to `Infrastructure/port-registry.json` under `internal`:

```json
"<name>": <next-available-port-in-21000-21999>
```

### 7. MCP Registration in opencode.json

Add to `Infrastructure/opencode/config/opencode.json`:

```json
"<name>": {
  "type": "sse",
  "url": "http://<name>:<port>/mcp/sse",
  "enabled": true,
  "timeout": 60000
}
```

### 8. Token Header Injection

Add to the `tokenMap` in `Infrastructure/opencode/entrypoint.sh`:

```js
'<name>': 'FLEET_API_TOKEN_<NAME>',
```

## Reference: Service Port Allocation

| Port | Service |
|------|---------|
| 21000-21001 | mcp_opencode |
| 21002 | is-fleet |
| 21003 | is-api |
| 21004 | mcp_aqe |
| 21005 | mcp_web (retired 2026-08-22) |
| 21007 | mcp_docusign (retired) |
| 21008 | is-bookkeeping (retired 2026-08-21) |
| 21009 | ops-funnel-proxy |
| 21010+ | Next available |

Internal ports are Docker overlay only (not host-mapped). Host ports (20100-39900) are for agent gateway services.

## Red lines

- **Do not create a new Node.js project with its own `package.json`** unless you need dependencies beyond `express` + `@modelcontextprotocol/sdk` + `express-rate-limit`. The monorepo pattern uses a single `npm install` in the Dockerfile.
- **Do not create a separate service** for functionality that fits into an existing MCP server (e.g., `is-bookkeeping`). Add MCP tools + REST endpoints to the existing server instead. A new service is only warranted when the domain is clearly separate (different auth model, different base image, different lifecycle).
- **Do not skip global rate limiting** — install `express-rate-limit` and apply middleware on every server (template above includes it). Without it, a single misbehaving agent can exhaust upstream API quotas for the entire fleet.
- **Do not skip per-agent rate limiting** if the MCP server makes external API calls (template above includes `checkPerAgentLimit`). This prevents one agent from starving others on the same service.
- **Do not make external API calls without retry/backoff** — wrap each call to rate-limited APIs (Tavily, Firecrawl, Zoho, OpenRouter, etc.) with the `retryWithBackoff` helper (template above). Retry only on 5xx / 429 / network errors, never on 4xx client errors. Use 3 attempts with ~500ms/1s/2s delays + jitter.
- **Do not hardcode API base URLs** — read from env vars with defaults (see Step 3d). This enables mock-server injection during testing and version upgrades without code changes.
- **Do not skip request timeouts** — use `fetchWithTimeout` (template above) for all outbound HTTP calls. Set `REQUEST_TIMEOUT` env var (default 30s). Without timeouts, a hung upstream can hold the request handler indefinitely.
- **Do not expose secrets in MCP tool output.** Redact keys, tokens, and credentials before returning results. Log only boolean presence (`'configured'`) not actual values.
- **Do not skip audit logging** — the template above includes `logAudit()` which writes structured JSON to stdout + an audit file. This is required for operational debugging and the `SalmonRun.Audit` compliance chain. Set `AUDIT_DIR` env var to control the log path.
- **Do not disable TLS validation in production** — never use `rejectUnauthorized: false` in TLS connections (IMAP, HTTPS), and do not add env-var opt-out knobs (e.g. `IMAP_TLS_REJECT_UNAUTHORIZED`). If a self-signed cert is unavoidable, add the CA to the image trust store instead.
- **Do follow the `fleet-auth.cjs` middleware pattern** for all REST endpoints — authentication is mandatory for fleet services.
- **Do register all routes in `/api/routes`** for discovery.
- **Do validate external URL inputs** — if your MCP tool accepts a URL parameter from the agent, validate it with `new URL()` and reject non-HTTP(S) schemes to prevent SSRF (see `validateUrl()` in the former `web-mcp-server.js`, retired 2026-08-22).

## Cross-References

- `Infrastructure/web-mcp-server.js` — ~~primary reference implementation~~ retired 2026-08-22; historical reference only (retry, rate limit, audit, timeouts, URL validation) <!-- doc-lint: exempt -->
- `Infrastructure/aqe-mcp-server.js` — MCP client-wrapper pattern (retired; see the mcp_aqe migration task) <!-- doc-lint: exempt -->
- `Infrastructure/auth/fleet-auth.cjs` — auth middleware
- `Infrastructure/mcp_browserless.Dockerfile` — reference for upstream image wrapping
- `Infrastructure/opencode/config/opencode.json` — MCP registration
- `Infrastructure/opencode/entrypoint.sh` — token injection
- `Infrastructure/port-registry.json` — port allocation
- `Skills/Docker/Modules/SalmonRun.Secrets/Private/bundle-manifest.ps1` — secret bundle schema
- `Skills/Docker/Modules/SalmonRun.Secrets/Public/` — publish functions
- `Skills/Docker/Modules/SalmonRun.Images/Public/` — build functions
- `Skills/Docker/Modules/SalmonRun.Deploy/Public/New-FleetCompose.ps1` — compose generation
- `Orchestrator/Modules/SalmonRun.Audit/` — audit module for PowerShell-side API call logging

## Changelog

- 2026-06-12: Added `express-rate-limit`, `fetchWithTimeout`, `retryWithBackoff`, and audit logging to template; enforced env-var-based API URLs; added per-agent rate limiting code
