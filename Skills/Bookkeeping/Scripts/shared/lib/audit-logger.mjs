import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import { createHash } from 'crypto';

const REPO_ROOT = (() => {
  try { return execSync('git rev-parse --show-toplevel', { encoding: 'utf8', timeout: 3000 }).trim(); }
  catch { return process.env.USERPROFILE + '/intersite-orchestrator'; }
})();

const DEFAULT_AUDIT_ROOT = process.env.ORCHESTRATOR_AUDIT_ROOT || path.resolve(REPO_ROOT, 'Tasks/Logs/Audit');

function sha256(content) {
  return createHash('sha256').update(JSON.stringify(content)).digest('hex');
}

function redactSecrets(headers, body) {
  const redactedHeaders = { ...headers };
  const secretKeys = ['authorization', 'api_key', 'api-key', 'secret', 'token', 'password', 'x-api-key'];
  for (const key of Object.keys(redactedHeaders)) {
    if (secretKeys.some(sk => key.toLowerCase().includes(sk))) {
      redactedHeaders[key] = '***';
    }
  }
  let redactedBody = body;
  if (typeof body === 'string') {
    try {
      const parsed = JSON.parse(body);
      redactedBody = { ...parsed };
      for (const key of Object.keys(redactedBody)) {
        if (secretKeys.some(sk => key.toLowerCase().includes(sk))) {
          redactedBody[key] = '***';
        }
      }
    } catch {
      redactedBody = body;
    }
  }
  return { headers: redactedHeaders, body: redactedBody };
}

function getAuditPath(domain) {
  const dir = path.resolve(DEFAULT_AUDIT_ROOT, domain);
  return path.join(dir, 'audit.jsonl');
}

function getLastHash(domain) {
  const auditPath = getAuditPath(domain);
  try {
    if (!fs.existsSync(auditPath)) return '';
    const content = fs.readFileSync(auditPath, 'utf8').trim();
    if (!content) return '';
    const lines = content.split('\n');
    const lastLine = lines[lines.length - 1].trim();
    if (!lastLine) return '';
    const lastEntry = JSON.parse(lastLine);
    return lastEntry.hash || '';
  } catch {
    return '';
  }
}

function writeAuditEntry(entry) {
  const domain = entry.domain || 'adhoc';
  const auditPath = getAuditPath(domain);
  const dir = path.dirname(auditPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  const prev = getLastHash(domain);
  const content = { ...entry, prev };
  content.hash = sha256(content);
  const line = JSON.stringify(content) + '\n';
  const tmpPath = auditPath + '.tmp';
  try {
    fs.writeFileSync(tmpPath, line, { encoding: 'utf8', flag: 'a' });
    fs.renameSync(tmpPath, auditPath);
    // Fall back to append if rename fails (cross-device)
  } catch {
    try {
      fs.appendFileSync(auditPath, line, 'utf8');
    } catch {}
  }
}

function cloneRequest(options) {
  const cloned = { method: (options && options.method) || 'GET' };
  if (options && options.headers) {
    cloned.headers = { ...options.headers };
  }
  if (options && options.body) {
    const bodyStr = typeof options.body === 'string' ? options.body : JSON.stringify(options.body);
    cloned.body = bodyStr;
  }
  return cloned;
}

async function fetchWithAudit(url, options = {}, auditMeta = {}) {
  const startTime = Date.now();
  const agent = process.env.OC_RESERVATION_AGENT_ID || 'unknown';
  const domain = auditMeta.domain || 'adhoc';
  const action = auditMeta.action || 'fetch';
  const session = auditMeta.session || '';

  const reqClone = cloneRequest(options);
  const redacted = redactSecrets(reqClone.headers, reqClone.body);

  const entryBase = {
    ts: new Date(startTime).toISOString(),
    agent,
    domain,
    action,
    session,
    req: {
      url: typeof url === 'string' ? url : url.toString(),
      method: (options && options.method) || 'GET',
      headers: redacted.headers,
      body: redacted.body,
    },
  };

  try {
    const response = await fetch(url, options);
    const endTime = Date.now();
    const durationMs = endTime - startTime;
    let responseBody = null;
    const contentType = response.headers.get('content-type') || '';
    if (contentType.includes('json')) {
      responseBody = await response.json();
    } else {
      responseBody = await response.text();
    }

    const entry = {
      ...entryBase,
      ms: durationMs,
      res: {
        status: response.status,
        body: typeof responseBody === 'object' ? JSON.stringify(responseBody).substring(0, 2000) : String(responseBody).substring(0, 2000),
      },
    };

    if (!response.ok) {
      entry.error = `HTTP ${response.status}: ${typeof responseBody === 'object' ? JSON.stringify(responseBody) : String(responseBody).substring(0, 200)}`;
    }

    writeAuditEntry(entry);

    return {
      ok: response.ok,
      status: response.status,
      data: responseBody,
    };
  } catch (err) {
    const endTime = Date.now();
    const durationMs = endTime - startTime;
    const entry = {
      ...entryBase,
      ms: durationMs,
      error: err.message,
    };
    writeAuditEntry(entry);
    throw err;
  }
}

export { fetchWithAudit, writeAuditEntry, getLastHash, getAuditPath };
