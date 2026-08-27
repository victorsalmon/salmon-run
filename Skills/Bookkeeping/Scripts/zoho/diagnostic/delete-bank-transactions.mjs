#!/usr/bin/env node
// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Get ONE token at session start, cache it, reuse for ALL calls. See known-issues.md.
import fs from 'fs';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { getSecret } = require('../shared/lib/get-secret.js');

const ZOHO_API_BASE = 'https://www.zohoapis.com/books/v3';
const ROOM_RENTALS_ORG = '925004567';

const DELETE_IDS = [
  "151803000000101051","151803000000116047","151803000000117061",
  "151803000000118077","151803000000119073","151803000000124100",
  "151803000000126109","151803000000126120","151803000000130066",
  "151803000000131065","151803000000131076","151803000000133047",
  "151803000000133058","151803000000134071","151803000000135038",
  "151803000000135039","151803000000135040","151803000000135042",
  "151803000000135047","151803000000135058","151803000000135063",
  "151803000000135065","151803000000135072","151803000000135105",
  "151803000000136063","151803000000141031","151803000000141042",
  "151803000000142049","151803000000143037","151803000000143048",
  "151803000000143059","151803000000144063","151803000000145045",
  "151803000000147033","151803000000148053","151803000000150039",
  "151803000000163003","151803000000163004","151803000000163005",
  "151803000000163006","151803000000163007","151803000000219021",
  "151803000000252062","151803000000297010","151803000000300021",
  "151803000000302022","151803000000304011","151803000000304021",
  "151803000000304031","151803000000305031","151803000000306021",
  "151803000000310012","151803000000311032","151803000000314001",
  "151803000000314011","151803000000315001","151803000000315011",
  "151803000000317011","151803000000318021","151803000000322001",
  "151803000000322011","151803000000323001","151803000000325011",
  "151803000000325021","151803000000325031","151803000000326011",
  "151803000000326021","151803000000327011","151803000000327021",
  "151803000000329001","151803000000329011","151803000000330001",
  "151803000000331001","151803000000332011","151803000000333001",
  "151803000000333011","151803000000334001","151803000000351103",
  "151803000000353127","151803000000364136","151803000000368126",
  "151803000000369126","151803000000387138","151803000000388080"
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

  const url = `${ZOHO_API_BASE}/banktransactions/${id}?organization_id=${ROOM_RENTALS_ORG}`;
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
  console.log(`Authenticated. Deleting ${DELETE_IDS.length} transactions from room-rentals org ${ROOM_RENTALS_ORG}...\n`);

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
