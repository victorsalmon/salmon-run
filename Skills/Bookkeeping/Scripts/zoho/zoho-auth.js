// Canonical Zoho REST API auth module (~18 consumers).
// Browser-based CDP session management lives in the (deprecated) zoho-session.mjs.
const fs = require('fs');
const path = require('path');
const TOKEN_URL = 'https://accounts.zoho.com/oauth/v2/token';

let singleton = null;

const ZOHO_AUDIT_DIR = process.env.ZOHO_AUDIT_DIR || '/var/log/zoho-audit';

function writeAuditEntry(entry) {
  try {
    const dir = ZOHO_AUDIT_DIR;
    fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'zoho-api-audit.jsonl'), JSON.stringify(entry) + '\n', 'utf8');
  } catch (err) {
    console.error(`[AUDIT] Failed to write audit entry: ${err.message}`);
  }
}

class ZohoAuth {
  constructor({ clientId, clientSecret, refreshToken }) {
    this.clientId = clientId;
    this.clientSecret = clientSecret;
    this.refreshToken = refreshToken;
    this.token = null;
    this.expiresAt = 0;
    this._cache = null;
    this.baseUrl = process.env.ZOHO_API_BASE_URL || 'https://www.zohoapis.com/books/v3';
  }

  static getInstance(opts) {
    if (!singleton) {
      if (!opts) throw new Error('ZohoAuth.getInstance() requires options on first call');
      singleton = new ZohoAuth(opts);
    }
    return singleton;
  }

  static resetInstance() {
    singleton = null;
  }

  static resolveCredentials() {
    const envRaw = process.env.ZOHO_SECRETS;
    if (envRaw) {
      try {
        return JSON.parse(envRaw);
      } catch (err) {
        console.error('Secrets JSON parse failed:', err.message);
        throw new Error('Failed to parse ZOHO_SECRETS: invalid JSON format');
      }
    }
    return require('../shared/lib/get-secret.js').getSecret();
  }

  static async ensureAuth() {
    if (singleton) return singleton;
    const creds = this.resolveCredentials();
    return this.getInstance({
      clientId: creds.ZOHO_BOOKS_ID,
      clientSecret: creds.ZOHO_BOOKS_SECRET,
      refreshToken: creds.ZOHO_BOOKS_REFRESH
    });
  }

  static async getAuthHeadersStatic() {
    const auth = await this.ensureAuth();
    await auth.getToken();
    return auth.headers;
  }

  async forceRefresh() {
    this.token = null;
    this.expiresAt = 0;
    return this.getToken();
  }

  async getToken() {
    if (this.token && Date.now() < this.expiresAt - 60000) {
      return this.token;
    }
    if (!this.token) {
      const cached = this._readCache();
      if (cached && cached.token && cached.expiresAt && Date.now() < cached.expiresAt - 60000) {
        this.token = cached.token;
        this.expiresAt = cached.expiresAt;
        return this.token;
      }
    }
    const body = new URLSearchParams({
      client_id: this.clientId,
      client_secret: this.clientSecret,
      refresh_token: this.refreshToken,
      grant_type: 'refresh_token'
    });
    const startTime = Date.now();
    const res = await fetch(TOKEN_URL, { method: 'POST', body });
    const durationMs = Date.now() - startTime;
    writeAuditEntry({
      timestamp: new Date(startTime).toISOString(),
      method: 'POST',
      path: '/oauth/v2/token',
      statusCode: res.status,
      durationMs,
    });
    if (!res.ok) {
      const text = await res.text();
      throw new Error("OAuth refresh failed (" + res.status + "): " + text);
    }
    const data = await res.json();
    this.token = data.access_token;
    this.expiresAt = Date.now() + (data.expires_in_sec || 3600) * 1000;
    this._writeCache();
    return this.token;
  }

  _readCache() {
    try {
      if (!this._cache) this._cache = require('./zoho-token-cache.js');
      return this._cache.read();
    } catch {
      return null;
    }
  }

  _writeCache() {
    try {
      if (!this._cache) this._cache = require('./zoho-token-cache.js');
      this._cache.write(this.token, this.expiresAt);
    } catch (err) {
      console.error(`[AUDIT] Failed to write token cache: ${err.message}`);
    }
  }

  get headers() {
    return { Authorization: "Zoho-oauthtoken " + this.token, "Content-Type": "application/json" };
  }

  apiUrl(path, orgId) {
    return this.baseUrl + path + "?organization_id=" + orgId;
  }
}

module.exports = { ZohoAuth };
