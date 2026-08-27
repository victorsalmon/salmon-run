import fs from 'fs';
import path from 'path';
import { ZohoAuth } from './zoho-auth.js';
import { ZohoRateLimiter } from './zoho-rate-limiter.mjs';
import { fetchWithAudit } from './lib/audit-logger.mjs';

const ORG_ID = '925048093';

const GIFI_MAP = {
  '93310000000149102': 8299,
  '93310000000000394': 8231,
  '93310000000000403': 8520,
  '93310000000000424': 8530,
  '93310000000000409': 8710,
  '93310000000000412': 8710,
  '93310000000151096': 8690,
  '93310000000000427': 8810,
  '93310000000217488': 8720,
  '93310000000000400': 8810,
  '93310000000135091': 8860,
  '93310000000000457': 8960,
  '93310000000000421': 9220,
  '93310000000000418': 8880,
  '93310000000000460': 9275,
  '93310000000582161': 9150,
};

async function setGifiCodes() {
  const auth = await ZohoAuth.ensureAuth();

  const token = await auth.getToken();
  console.log('Authenticated - token ready');

  const limiter = new ZohoRateLimiter({ minGapMs: 500, batchSleepMs: 3000 });
  const entries = Object.entries(GIFI_MAP);
  console.log(`\nUpdating ${entries.length} accounts with GIFI codes...\n`);

  let success = 0;
  let failed = 0;

  for (const [accountId, gifiCode] of entries) {
    await limiter.batchWait();

    try {
      const url = `https://www.zohoapis.com/books/v3/chartofaccounts/${accountId}?organization_id=${ORG_ID}`;
      const body = JSON.stringify({ account_code: String(gifiCode) });

      const resp = await fetchWithAudit(url, {
        method: 'PUT',
        headers: {
          'Authorization': `Zoho-oauthtoken ${await auth.getToken()}`,
          'Content-Type': 'application/json',
        },
        body,
      }, { domain: 'Bookkeeper', action: 'zoho:chartofaccounts:update' });
      if (!resp.ok) throw new Error(`API ${resp.status}: ${JSON.stringify(resp.data)}`);
      const data = resp.data;

      if (data.code === 0) {
        console.log(`  OK  ${accountId} -> GIFI ${gifiCode}`);
        success++;
      } else if (data.code === 1002) {
        console.log(`  RATE ${accountId} -> waiting 10s...`);
        await new Promise(r => setTimeout(r, 10000));
        const retryResp = await fetchWithAudit(url, { method: 'PUT', headers: { 'Authorization': `Zoho-oauthtoken ${await auth.getToken()}`, 'Content-Type': 'application/json' }, body }, { domain: 'Bookkeeper', action: 'zoho:chartofaccounts:update' });
        const retryData = retryResp.data;
        if (retryData.code === 0) {
          console.log(`  OK  ${accountId} -> GIFI ${gifiCode} (retry)`);
          success++;
        } else {
          console.log(`  FAIL ${accountId} -> ${retryData.message} (retry)`);
          failed++;
        }
      } else {
        console.log(`  FAIL ${accountId} -> ${data.message}`);
        failed++;
      }
    } catch (err) {
      console.log(`  ERR  ${accountId} -> ${err.message}`);
      failed++;
    }
  }

  console.log(`\nDone - ${success} updated, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

setGifiCodes().catch(err => {
  console.error(`Fatal: ${err.message}`);
  process.exit(1);
});

