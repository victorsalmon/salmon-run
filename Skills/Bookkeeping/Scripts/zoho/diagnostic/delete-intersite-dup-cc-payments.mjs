#!/usr/bin/env node
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { getSecret } = require('../shared/lib/get-secret.js');

const ZOHO_API_BASE = 'https://www.zohoapis.com/books/v3';
const INTERSITE_ORG = '925048093';

const DELETE_IDS = [
  // Duplicate CC interest expense entries ($10 each)
  "93310000000201276",
  "93310000000211215",
  "93310000000209281",
  "93310000000201296",
  // Duplicate CC interest expense entry ($12)
  "93310000000230234",
  // Phantom $8 manually-added opening balance
  "93310000000590040"
];

function resolveCreds() {
  if (process.env.ZOHO_BOOKS_ID && process.env.ZOHO_BOOKS_SECRET && process.env.ZOHO_BOOKS_REFRESH) {
    return { clientId: process.env.ZOHO_BOOKS_ID, clientSecret: process.env.ZOHO_BOOKS_SECRET, refreshToken: process.env.ZOHO_BOOKS_REFRESH };
  }
  try {
    const parsed = getSecret();
    return { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  } catch {}
  throw new Error('Could not resolve Zoho credentials');
}

let _token = null;
async function getToken(creds) {
  if (_token) return _token;
  const body = new URLSearchParams({
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    refresh_token: creds.refreshToken,
    grant_type: 'refresh_token'
  });
  const resp = await fetch('https://accounts.zoho.com/oauth/v2/token', { method: 'POST', body });
  if (!resp.ok) throw new Error(`OAuth failed: ${resp.status}`);
  const data = await resp.json();
  _token = data.access_token;
  return _token;
}

let _lastCall = 0;
let _callCount = 0;
async function deleteTransaction(id, token) {
  const now = Date.now();
  const gap = now - _lastCall;
  if (gap < 400) await new Promise(r => setTimeout(r, 400 - gap));
  _lastCall = Date.now();
  _callCount++;

  if (_callCount % 10 === 0) {
    console.log(`  Rate limit pause (${_callCount} calls)...`);
    await new Promise(r => setTimeout(r, 2000));
  }

  const url = `${ZOHO_API_BASE}/banktransactions/${id}?organization_id=${INTERSITE_ORG}`;
  const resp = await fetch(url, {
    method: 'DELETE',
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const data = await resp.json();
  return { status: resp.status, code: data.code, message: data.message, id };
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  if (dryRun) console.log('═══ DRY RUN — no deletions will be performed ═══\n');

  console.log(`Resolving credentials...`);
  const creds = resolveCreds();
  const token = await getToken(creds);
  console.log(`Authenticated. Deleting ${DELETE_IDS.length} duplicate CC payment entries from Intersite org ${INTERSITE_ORG}...\n`);

  const results = { success: [], failed: [], skipped: [] };

  for (let i = 0; i < DELETE_IDS.length; i++) {
    const id = DELETE_IDS[i];
    const pct = ((i + 1) / DELETE_IDS.length * 100).toFixed(0);
    process.stdout.write(`  [${pct}%] Deleting ${id}... `);

    if (dryRun) {
      console.log(`SKIP (dry-run)`);
      results.skipped.push(id);
      continue;
    }

    try {
      const result = await deleteTransaction(id, token);
      if (result.code === 0) {
        console.log(`OK`);
        results.success.push(id);
      } else {
        console.log(`FAILED: ${result.message} (code=${result.code})`);
        results.failed.push({ id, message: result.message, code: result.code });
      }
    } catch (err) {
      console.log(`ERROR: ${err.message}`);
      results.failed.push({ id, message: err.message, code: -1 });
    }
  }

  console.log(`\n═══ Results ═══`);
  console.log(`  Total:     ${DELETE_IDS.length}`);
  console.log(`  Deleted:   ${results.success.length}`);
  console.log(`  Failed:    ${results.failed.length}`);
  console.log(`  Skipped:   ${results.skipped.length}`);

  if (results.failed.length > 0) {
    console.log(`\n  Failed IDs:`);
    results.failed.forEach(f => console.log(`    ${f.id}: ${f.message}`));
  }
}

main().catch(err => { console.error(`\nFATAL: ${err.message}`); process.exit(1); });
