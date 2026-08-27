import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';

const ORG_ROOM_RENTALS = '925004567';
const CACHE_FILE = '.zoho-bank-accounts.json';
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const CONTAINER_NAME = 'FRAD_is-bookkeeping';
const ACCOUNT_KEYS = [
  { key: 'td-mlm',    filter: 'TD' },
  { key: 'scotia-tmh', filter: 'SCOTIA' },
  { key: 'rbc-fra',   filter: 'RBC' },
];

function readCache() {
  if (fs.existsSync(CACHE_FILE)) {
    const raw = fs.readFileSync(CACHE_FILE, 'utf8');
    try {
      const cached = JSON.parse(raw);
      if (Date.now() - cached.ts < CACHE_TTL_MS) {
        return cached.accounts;
      }
    } catch {}
  }
  return null;
}

function writeCache(accounts) {
  fs.writeFileSync(CACHE_FILE, JSON.stringify({ ts: Date.now(), accounts }, null, 2), 'utf8');
}

function resolveFromContainer(orgId, filter) {
  const containerId = execSync(
    `docker ps --filter name=${CONTAINER_NAME} --format "{{.ID}}"`,
    { encoding: 'utf8' }
  ).trim();
  if (!containerId) {
    throw new Error(`${CONTAINER_NAME} container not found — is the fleet running?`);
  }

  const url = filter
    ? `http://localhost:21008/zoho/bank-accounts?org_id=${orgId}&filter=${filter}`
    : `http://localhost:21008/zoho/bank-accounts?org_id=${orgId}`;

  const responseJson = execSync(
    `docker exec ${containerId} curl -s "${url}"`,
    { encoding: 'utf8', timeout: 15000 }
  );

  const response = JSON.parse(responseJson);
  if (!response.Success) {
    throw new Error(`Failed to resolve bank accounts: ${response.Message || JSON.stringify(response)}`);
  }

  return response.Data;
}

function resolveAccountIds(orgId, options = {}) {
  const cacheFile = options.cacheFile || CACHE_FILE;

  const cached = readCache();
  if (cached && !options.force) {
    return cached;
  }

  const result = resolveFromContainer(orgId, null);
  writeCache(result);
  return result;
}

function getAccountId(orgId, accountKey) {
  const accounts = resolveAccountIds(orgId);
  const match = ACCOUNT_KEYS.find(a => a.key === accountKey);
  if (!match) throw new Error(`Unknown account key: ${accountKey}`);

  const account = accounts.find(a =>
    a.account_name && a.account_name.toLowerCase().includes(match.filter.toLowerCase())
  );
  if (!account) throw new Error(`No account found matching key "${accountKey}" (filter: ${match.filter})`);

  return account.account_id;
}

function main() {
  try {
    const accounts = resolveAccountIds(ORG_ROOM_RENTALS);
    console.log('Resolved bank accounts for Room Rentals (org 925004567):');
    console.log('');

    for (const a of ACCOUNT_KEYS) {
      const account = accounts.find(acct =>
        acct.account_name && acct.account_name.toLowerCase().includes(a.filter.toLowerCase())
      );
      if (account) {
        console.log(`  ${a.key.padEnd(15)} → ${account.account_name.padEnd(35)} ${account.account_id}`);
      } else {
        console.log(`  ${a.key.padEnd(15)} → NOT FOUND`);
      }
    }
  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

if (process.argv[1] && (process.argv[1].endsWith('resolve-zoho-bank-accounts.mjs') || process.argv[1].endsWith('resolve-zoho-bank-accounts'))) {
  main();
}

export { resolveAccountIds, getAccountId, ACCOUNT_KEYS, ORG_ROOM_RENTALS };
