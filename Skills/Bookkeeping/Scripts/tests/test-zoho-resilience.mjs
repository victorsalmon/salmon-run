// test-zoho-resilience.mjs — unit tests for Zoho auth resilience fixes
import assert from 'assert/strict';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);

// --- Task 1: get-secret.js surfaces actionable errors ---
{
  const cp = require('child_process');
  const original = cp.execFileSync;
  cp.execFileSync = () => {
    const err = new Error('Command failed: aws secretsmanager get-secret-value');
    err.stderr = Buffer.from('An error occurred (ExpiredTokenException)');
    throw err;
  };
  const { getSecret } = require('../shared/lib/get-secret.js');
  let thrown = null;
  try {
    getSecret();
  } catch (err) {
    thrown = err;
  }
  cp.execFileSync = original;
  assert.ok(thrown, 'getSecret should throw on aws failure');
  assert.ok(thrown.message.includes('Interclaw/FRAD/Provisioning'), 'error should mention the secret ID');
  assert.ok(thrown.message.includes('AWS SSO'), 'error should carry SSO remediation guidance');
  assert.ok(thrown.cause, 'error should preserve stderr as cause');
  assert.ok(thrown.cause.includes('ExpiredTokenException'), 'cause should contain raw stderr');
}

// --- Task 1b: env-based resolution does not force the interclaw profile ---
{
  const cp = require('child_process');
  const original = cp.execFileSync;
  let lastArgs = null;
  cp.execFileSync = (cmd, args) => {
    lastArgs = args;
    return JSON.stringify({ ZOHO_BOOKS_ID: 'x', ZOHO_BOOKS_SECRET: 'y', ZOHO_BOOKS_REFRESH: 'z' });
  };
  delete process.env.AWS_PROFILE;
  delete require.cache[require.resolve('../shared/lib/get-secret.js')];
  const { getSecret } = require('../shared/lib/get-secret.js');
  const out = getSecret();
  cp.execFileSync = original;
  assert.ok(out.ZOHO_BOOKS_ID, 'secret parsed');
  assert.ok(!lastArgs.includes('--profile'), 'no --profile flag when AWS_PROFILE unset');
}

// --- Task 2: token cache is project-aware ---
{
  process.env.INSTALL_PROJECT = 'TESTPROJ';
  delete require.cache[require.resolve('../zoho/zoho-token-cache.js')];
  const cache = require('../zoho/zoho-token-cache.js');
  assert.equal(cache.VOLUME_NAME, 'TESTPROJ_zoho_token_cache', 'volume derives from INSTALL_PROJECT');
  delete process.env.INSTALL_PROJECT;
}

{
  delete require.cache[require.resolve('../zoho/zoho-token-cache.js')];
  const cache = require('../zoho/zoho-token-cache.js');
  assert.equal(cache.VOLUME_NAME, 'FRAD_zoho_token_cache', 'FRAD remains the documented default');
}

// --- Task 3: rate limiter retries network errors and 5xx ---
{
  const { ZohoRateLimiter } = await import('../zoho/zoho-rate-limiter.mjs');
  const limiter = new ZohoRateLimiter({ minGapMs: 0, batchSleepMs: 0 });

  // Network error twice, then success
  let calls = 0;
  const origFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    calls++;
    if (calls <= 2) throw new TypeError('fetch failed');
    return { status: 200 };
  };
  const r1 = await limiter.fetchWithRetry('https://example.com');
  assert.equal(calls, 3, 'two network failures should be retried');
  assert.equal(r1.status, 200, 'final success returned');

  // 503 twice, then 200
  calls = 0;
  globalThis.fetch = async () => {
    calls++;
    if (calls <= 2) return { status: 503 };
    return { status: 200 };
  };
  const r2 = await limiter.fetchWithRetry('https://example.com');
  assert.equal(calls, 3, 'two 503s should be retried');
  assert.equal(r2.status, 200, 'final 200 returned');

  // Persistent 500 returns last response
  calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return { status: 500 };
  };
  const r3 = await limiter.fetchWithRetry('https://example.com');
  assert.equal(calls, 4, 'maxRetries+1 attempts (initial + 3 retries)');
  assert.equal(r3.status, 500, 'persistent failure returns last response');

  // 429 still retried
  calls = 0;
  globalThis.fetch = async () => {
    calls++;
    if (calls <= 1) return { status: 429 };
    return { status: 200 };
  };
  const r4 = await limiter.fetchWithRetry('https://example.com');
  assert.equal(calls, 2, '429 retried once');
  assert.equal(r4.status, 200, '429 recovery returns 200');
  globalThis.fetch = origFetch;
}

console.log('All zoho-resilience tests passed.');
