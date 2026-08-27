// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Get ONE token at session start, cache it, reuse for ALL calls. See known-issues.md.
import { execSync } from 'child_process';
import fs from 'fs';

// Grab creds from Bookkeeping container bundle
const bundleRaw = execSync(
  'docker exec FRAD_is-bookkeeping.1.b3qhs5n23bakppkcrq79za4uy cat /run/secrets/bookkeeping_secrets_bundle',
  { encoding: 'utf8', timeout: 10000 }
);
const bundle = JSON.parse(bundleRaw.trim());

const tokenResp = await fetch('https://accounts.zoho.com/oauth/v2/token', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    client_id: bundle.ZOHO_BOOKS_ID,
    client_secret: bundle.ZOHO_BOOKS_SECRET,
    refresh_token: bundle.ZOHO_BOOKS_REFRESH,
    grant_type: 'refresh_token'
  })
});
const tokenData = await tokenResp.json();
const token = tokenData.access_token;
if (!token) { console.error('Token failed:', JSON.stringify(tokenData)); process.exit(1); }

const base = 'https://www.zohoapis.com/books/v3';
const orgId = bundle.ZOHO_BOOKS_ORG_INTERSITE;

async function api(path) {
  const url = `${base}${path}&organization_id=${orgId}`;
  const resp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const data = await resp.json();
  return data;
}

export async function getToken() {
  return token;
}

export async function getOrgId() {
  return orgId;
}

export { api };

// Only run main if executed directly
if (import.meta.url === `file:///${process.argv[1].replace(/\\/g, '/')}`) {
  const acctId = process.argv[2]; // optional filter

  if (!acctId || acctId === '9990') {
    console.log('=== INCOME TAX EXPENSE [9990] — BANK TRANSACTIONS ===');
    const iteBt = await api(`/banktransactions?account_id=93310000000297002&from_date=2025-04-01&to_date=2026-03-31&per_page=200`);
    for (const bt of iteBt.banktransactions || []) {
      const amt = parseFloat(bt.amount);
      const dir = amt >= 0 ? 'DR' : 'CR';
      console.log(`${bt.date} | ${(bt.payee||'').padEnd(30)} | ${dir} $${Math.abs(amt).toFixed(2).padStart(8)} | ${bt.description||''}`);
    }
  }

  if (!acctId || acctId === 'advert') {
    const advId = '93310000000000403';
    console.log('\n=== ADVERTISING [8521] — BANK TRANSACTIONS ===');
    const advBt = await api(`/banktransactions?account_id=${advId}&from_date=2025-04-01&to_date=2026-03-31&per_page=200`);
    for (const bt of advBt.banktransactions || []) {
      const amt = parseFloat(bt.amount);
      console.log(`${bt.date} | ${(bt.payee||bt.description||'').padEnd(30)} | amount:$${amt.toFixed(2).padStart(8)} | id=${bt.bank_transaction_id}`);
    }
  }
}
