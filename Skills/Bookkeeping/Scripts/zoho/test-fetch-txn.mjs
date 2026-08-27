#!/usr/bin/env node
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { getSecret } = require('../shared/lib/get-secret.js');

async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };

  const body = new URLSearchParams({
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    refresh_token: creds.refreshToken,
    grant_type: 'refresh_token'
  });
  const resp = await fetch('https://accounts.zoho.com/oauth/v2/token', { method: 'POST', body });
  const data = await resp.json();
  const token = data.access_token;

  // Try to fetch one of the duplicate entries by ID
  const testId = '93310000000220007';
  const url = `https://www.zohoapis.com/books/v3/banktransactions/${testId}?organization_id=925048093`;
  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  console.log(JSON.stringify(result, null, 2));
}
main().catch(e => console.error(e.message));
