/**
 * Restore-OpeningBalances.mjs
 *
 * Safely restores Zoho Books opening balances from the canonical JSON source.
 * Implements the read-before-write safeguard: GETs current opening balances,
 * merges with the canonical source, never drops user-set adjustments.
 *
 * Usage:
 *   node Restore-OpeningBalances.mjs --dry-run     # preview only
 *   node Restore-OpeningBalances.mjs                # apply
 *   node Restore-OpeningBalances.mjs --org intersite|room-rentals  # single org
 *
 * ============================================================================
 * SAFEGUARD: PUT /settings/openingbalances REPLACES the entire list.
 * If you send only 1 account, Zoho deletes all others. This script always:
 *   1. GETs the current opening balances from Zoho
 *   2. Merges canonical values (this file wins for known accounts)
 *   3. Preserves any extra accounts in Zoho that this file doesn't know about
 *   4. PUTs the complete merged list back
 * ============================================================================
 */

import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, '..', '..', '..', '..');

// ─── Config ───────────────────────────────────────────────────────────────
const CANONICAL_PATH = join(REPO_ROOT, 'Skills', 'Bookkeeping', '_organizations', 'opening-balances.json');
const AWS_CLI = 'C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe';
const AWS_PROFILE = 'intersite';
const AWS_REGION = 'ca-central-1';
const AWS_SECRET_ID = 'Interclaw/FRAD/Provisioning';
const ZOHO_API_BASE = 'https://www.zohoapis.com/books/v3';

// ─── CLI ──────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const orgFilter = args.includes('--org') ? args[args.indexOf('--org') + 1] : null;

if (dryRun) console.log('>>> DRY RUN MODE — no changes will be made\n');

// ─── Helpers ──────────────────────────────────────────────────────────────

function loadCanonical() {
  const raw = readFileSync(CANONICAL_PATH, 'utf8');
  return JSON.parse(raw);
}

async function getAwsSecrets() {
  const { execSync } = await import('child_process');
  const cmd = `"${AWS_CLI}" secretsmanager get-secret-value --secret-id ${AWS_SECRET_ID} --profile ${AWS_PROFILE} --region ${AWS_REGION} --query SecretString --output text`;
  const stdout = execSync(cmd, { encoding: 'utf8', timeout: 15000 });
  return JSON.parse(stdout.trim());
}

async function getZohoToken(auth) {
  const resp = await fetch('https://accounts.zoho.com/oauth/v2/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      refresh_token: auth.refreshToken,
      client_id: auth.clientId,
      client_secret: auth.clientSecret,
      grant_type: 'refresh_token'
    })
  });
  const data = await resp.json();
  if (!data.access_token) throw new Error(`OAuth failed: ${JSON.stringify(data)}`);
  return data.access_token;
}

async function getCurrentOpeningBalances(orgId, token) {
  const url = `${ZOHO_API_BASE}/settings/openingbalances?organization_id=${orgId}`;
  const resp = await fetch(url, {
    headers: { 'Authorization': `Zoho-oauthtoken ${token}` }
  });
  const data = await resp.json();
  if (data.code !== 0) throw new Error(`GET openingbalances failed: ${data.message}`);
  return data.opening_balances || [];
}

async function putOpeningBalances(orgId, token, openingBalances) {
  const url = `${ZOHO_API_BASE}/settings/openingbalances?organization_id=${orgId}`;
  const body = JSON.stringify({ opening_balances: openingBalances });
  const resp = await fetch(url, {
    method: 'PUT',
    headers: {
      'Authorization': `Zoho-oauthtoken ${token}`,
      'Content-Type': 'application/json'
    },
    body
  });
  const data = await resp.json();
  return data;
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function restoreOrg(orgInfo, canonicalAccounts, token) {
  const orgId = orgInfo.org_id;
  const orgName = orgInfo.org_name;

  console.log(`\n=== ${orgName} (${orgId}) ===`);

  // Step 1: GET current state
  console.log('  Reading current opening balances from Zoho...');
  const current = await getCurrentOpeningBalances(orgId, token);
  console.log(`  Found ${current.length} existing opening balance(s):`);
  for (const ob of current) {
    console.log(`    ${ob.account_id}: $${ob.opening_balance} (${ob.entry_date || 'no date'})`);
  }

  // Step 2: Build merged list — canonical wins, preserve extras
  const canonicalMap = new Map();
  for (const acct of canonicalAccounts) {
    canonicalMap.set(acct.account_id, {
      account_id: acct.account_id,
      opening_balance: acct.opening_balance,
      entry_date: acct.entry_date
    });
  }

  const merged = new Map();

  // Copy canonical values
  for (const [acctId, ob] of canonicalMap) {
    merged.set(acctId, ob);
  }

  // Copy Zoho values for accounts NOT in canonical (preserve user-set adjustments)
  for (const ob of current) {
    if (!canonicalMap.has(ob.account_id)) {
      console.log(`  PRESERVING extra account: ${ob.account_id} ($${ob.opening_balance}) — not in canonical source`);
      merged.set(ob.account_id, {
        account_id: ob.account_id,
        opening_balance: ob.opening_balance,
        entry_date: ob.entry_date
      });
    }
  }

  const finalList = Array.from(merged.values());

  console.log(`\n  Final opening balance list (${finalList.length} accounts):`);
  for (const ob of finalList) {
    const source = canonicalMap.has(ob.account_id) ? 'canonical' : 'preserved-from-zoho';
    console.log(`    ${ob.account_id}: $${ob.opening_balance} (${ob.entry_date || 'no date'}) [${source}]`);
  }

  // Step 3: Dry-run or PUT
  if (dryRun) {
    console.log('\n  DRY RUN — skipping PUT. To apply, re-run without --dry-run.');
    return;
  }

  // Check if anything actually changed
  const currentSorted = [...current].sort((a, b) => a.account_id.localeCompare(b.account_id));
  const finalSorted = [...finalList].sort((a, b) => a.account_id.localeCompare(b.account_id));
  const changed = JSON.stringify(currentSorted) !== JSON.stringify(finalSorted);

  if (!changed) {
    console.log('\n  No changes needed — opening balances already match canonical source.');
    return;
  }

  console.log('\n  PUT /settings/openingbalances...');
  const result = await putOpeningBalances(orgId, token, finalList);

  if (result.code === 0) {
    console.log('  SUCCESS: Opening balances updated.');
  } else {
    console.error(`  FAILED: code=${result.code} message=${result.message}`);
    if (result.message) console.error(`  Details: ${JSON.stringify(result)}`);
    process.exitCode = 1;
  }
}

async function main() {
  // Load canonical source
  if (!existsSync(CANONICAL_PATH)) {
    console.error(`ERROR: Canonical file not found at ${CANONICAL_PATH}`);
    process.exit(1);
  }
  const canonical = loadCanonical();
  console.log(`Loaded canonical opening balances from ${CANONICAL_PATH}`);
  console.log(`Schema: ${canonical._schema}`);

  // Authenticate
  console.log('\nAuthenticating with Zoho...');
  const secrets = await getAwsSecrets();
  const auth = {
    clientId: secrets.ZOHO_BOOKS_ID,
    clientSecret: secrets.ZOHO_BOOKS_SECRET,
    refreshToken: secrets.ZOHO_BOOKS_REFRESH
  };
  const token = await getZohoToken(auth);
  console.log('Authenticated.\n');

  // Process each org
  for (const org of canonical.organizations) {
    if (orgFilter) {
      const slug = org.org_name.toLowerCase().replace(/[^a-z0-9]+/g, '-');
      if (slug !== orgFilter && org.org_id !== orgFilter) continue;
    }
    await restoreOrg(org, org.accounts, token);
  }

  console.log('\nDone.');
}

main().catch(e => {
  console.error(`FATAL: ${e.message}`);
  console.error(e.stack);
  process.exit(1);
});
