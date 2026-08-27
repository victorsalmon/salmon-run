#!/usr/bin/env node
// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Tokens last 1 hour. Get ONE token at session start, cache it, reuse for ALL calls.
// Never call the OAuth endpoint more than once per session. See known-issues.md.

import fs from 'fs';
import os from 'os';
import path from 'path';
import crypto from 'crypto';
import { execSync } from 'child_process';
import { fetchWithAudit } from '../shared/lib/audit-logger.mjs';
import { ZohoAuth } from './zoho-auth.js';

// ── Configuration ──────────────────────────────────────────────────────────

const FY_START = '2025-04-01';
const FY_END   = '2026-03-31';
const ORG_SLUG = 'intersite-consulting';

const HOME = process.env.USERPROFILE || os.homedir();

const REPORTS_DIR = path.resolve(
  HOME,
  'intersite-docs',
  'Taxes and Bookkeeping', 'intersite-consulting',
  '2026 Filing', '2026-zoho-reports'
);

const LOG_FILE = path.join(REPORTS_DIR, '_sync-log.jsonl');
const SECRET_NAMES = [
  'ZOHO_BOOKS_ID', 'ZOHO_BOOKS_SECRET', 'ZOHO_BOOKS_REFRESH', 'ZOHO_BOOKS_ORG_INTERSITE'
];

// ── Report definitions ──────────────────────────────────────────────────────
//
// Each entry: { file, method, buildUrl(orgId) }
// Order matters — chartofaccounts must be fetched early so per-account GL
// calls can resolve account names to IDs.

const REPORT_DEFS = [
  // Main reports (no account ID needed)
  { file: 'profit-and-loss.json',       method: 'GET', buildUrl: id => `/reports/profitandloss?from_date=${FY_START}&to_date=${FY_END}&organization_id=${id}` },
  { file: 'trial-balance.json',         method: 'GET', buildUrl: id => `/reports/trialbalance?from_date=${FY_START}&to_date=${FY_END}&organization_id=${id}` },
  { file: 'balance-sheet.json',         method: 'GET', buildUrl: id => `/reports/balancesheet?from_date=${FY_START}&to_date=${FY_END}&organization_id=${id}` },
  { file: 'general-ledger.json',        method: 'GET', buildUrl: id => `/reports/generalledger?from_date=${FY_START}&to_date=${FY_END}&organization_id=${id}` },
  { file: 'chart-of-accounts.json',     method: 'GET', buildUrl: id => `/chartofaccounts?organization_id=${id}&per_page=200` },
  { file: 'tax-summary.json',           method: 'GET', buildUrl: id => `/reports/taxsummary?from_date=${FY_START}&to_date=${FY_END}&organization_id=${id}` },
  { file: 'ar-aging.json',             method: 'GET', buildUrl: id => `/reports/accountsreceivableaging?as_of_date=${FY_END}&organization_id=${id}` },
  { file: 'ap-aging.json',             method: 'GET', buildUrl: id => `/reports/accountspayableaging?as_of_date=${FY_END}&organization_id=${id}` },
  { file: 'fixed-asset-schedule.json',  method: 'GET', buildUrl: id => `/reports/fixedassetschedule?as_of_date=${FY_END}&organization_id=${id}` },

  // Per-account GL files — extracted locally from the full GL response.
  // The `nameHint` field matches against chart of accounts by name.
  { file: 'gl-consulting-revenue.json',  nameHint: 'Consulting Revenue' },
  { file: 'gl-gst-hst-payable.json',     nameHint: 'GST/HST Payable' },
  { file: 'gl-automobile.json',          nameHint: 'Automobile Expense' },
  { file: 'gl-intersite-bank.json',      nameHint: 'Intersite' },
  { file: 'gl-mc-6258.json',             nameHint: '6258' },
  { file: 'gl-office-general.json',      nameHint: 'Office & General' },
  { file: 'gl-other-expenses.json',      nameHint: 'Other Expenses' },
  { file: 'gl-professional-fees.json',   nameHint: 'Professional Fees' },
  { file: 'gl-repairs-maintenance.json', nameHint: 'Repairs and Maintenance' },
  { file: 'gl-software-it.json',         nameHint: 'Software & IT' },
  { file: 'account-transactions-shareholder-loan.json', nameHint: 'Shareholder Loan' },
  { file: 'gl-cit-payable.json',             nameHint: 'Corporate Income Tax' },
  { file: 'gl-dividends-paid.json',          nameHint: 'Dividend' },
  { file: 'gl-interest-income.json',         nameHint: 'Interest Income' },
  { file: 'gl-advertising.json',             nameHint: 'Advertising' },
  { file: 'gl-bank-fees.json',               nameHint: 'Bank Fees' },
  { file: 'gl-lease.json',                   nameHint: 'Lease Expense' },
];

// ── Credential resolution ──────────────────────────────────────────────────

function resolveCreds() {
  // 1. Environment variables (fastest, suitable for container runs)
  if (process.env.ZOHO_BOOKS_ID && process.env.ZOHO_BOOKS_SECRET && process.env.ZOHO_BOOKS_REFRESH) {
    return {
      clientId: process.env.ZOHO_BOOKS_ID,
      clientSecret: process.env.ZOHO_BOOKS_SECRET,
      refreshToken: process.env.ZOHO_BOOKS_REFRESH,
      orgId: process.env.ZOHO_BOOKS_ORG_INTERSITE || '925048093'
    };
  }

  // 2. AWS Secrets Manager (host machine, fleet not required)
  try {
    const { getSecret } = require('../shared/lib/get-secret');
    const parsed = getSecret();
    const creds = {
      clientId: parsed.ZOHO_BOOKS_ID,
      clientSecret: parsed.ZOHO_BOOKS_SECRET,
      refreshToken: parsed.ZOHO_BOOKS_REFRESH,
      orgId: parsed.ZOHO_BOOKS_ORG_INTERSITE || '925048093'
    };
    return creds;
  } catch (e) {
    console.warn('AWS SM failed:', e.message.substring(0, 80));
  }

  // 3. Docker proxy container (requires fleet running)
  try {
    const containerId = execSync(
      'docker ps --filter name=FRAD_api-proxy --format "{{.ID}}"',
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
    if (!containerId) throw new Error('proxy container not found');

    const bundleJson = execSync(
      `docker exec ${containerId} cat /run/secrets/secrets_bundle`,
      { encoding: 'utf8', timeout: 10000 }
    );
    const bundle = JSON.parse(bundleJson);
    const creds = {
      clientId: bundle.ZOHO_BOOKS_ID,
      clientSecret: bundle.ZOHO_BOOKS_SECRET,
      refreshToken: bundle.ZOHO_BOOKS_REFRESH,
      orgId: bundle.ZOHO_BOOKS_ORG_INTERSITE || '925048093'
    };
    return creds;
  } catch (e) {
    console.warn('Docker proxy failed:', e.message.substring(0, 80));
  }

  throw new Error(
    'Could not resolve Zoho credentials. ' +
    'Set env ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH, or ensure AWS CLI / Docker fleet is available.'
  );
}

// ── API call with rate limiting ────────────────────────────────────────────

let _lastCall = 0;
let _callCount = 0;

async function zohoFetch(url, token, acceptPdf = false) {
  const now = Date.now();
  const gap = now - _lastCall;
  if (gap < 350) await new Promise(r => setTimeout(r, 350 - gap));
  _lastCall = Date.now();
  _callCount++;

  if (_callCount % 10 === 0) {
    await new Promise(r => setTimeout(r, 2000));
  }

  const headers = { Authorization: `Zoho-oauthtoken ${token}` };
  if (acceptPdf) headers['Accept'] = 'application/pdf';

  const resp = await fetchWithAudit(url, { headers }, { domain: 'Bookkeeper', action: 'zoho:reports:fetch' });

  if (!resp.ok) {
    const errMsg = `API ${resp.status} for ${url.substring(0, 100)}: ${JSON.stringify(resp.data).substring(0, 200)}`;
    // 404 on aging/fixed-asset reports is expected — no AR/AP/FA tracked in Zoho for this org
    if (resp.status === 404 && (url.includes('aging') || url.includes('fixedasset'))) {
      console.warn(`  ⚠ ${errMsg} (non-essential, skipping)`);
      return null;
    }
    throw new Error(errMsg);
  }

  return resp.data;
}

// ── File helpers ──────────────────────────────────────────────────────────

function sha256(content) {
  return crypto.createHash('sha256').update(content).digest('hex');
}

function readExisting(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }
}

// ── Chart of accounts resolver ────────────────────────────────────────────

function buildAccountMap(coaData) {
  const map = {};
  const accounts = coaData.chartofaccounts || coaData.chart_of_accounts || [];
  for (const acct of accounts) {
    if (acct.account_name) {
      map[acct.account_name.trim().toLowerCase()] = acct.account_id;
    }
    if (acct.account_code) {
      map[acct.account_code.trim().toLowerCase()] = acct.account_id;
    }
  }
  return map;
}

function resolveAccountId(accountMap, nameHint) {
  const key = nameHint.trim().toLowerCase();
  if (accountMap[key]) return accountMap[key];

  // Fuzzy: match if hint is contained in a known name
  for (const [name, id] of Object.entries(accountMap)) {
    if (name.includes(key) || key.includes(name)) return id;
  }

  return null;
}

// ── Per-account GL filter ─────────────────────────────────────────────────

function filterGlByAccount(fullGl, accountId) {
  const gl = JSON.parse(JSON.stringify(fullGl));
  gl.generalledger = (gl.generalledger || []).filter(
    a => a.account_id === accountId
  );
  return gl;
}

// ── Sync log ──────────────────────────────────────────────────────────────

function appendLog(entry) {
  try {
    fs.mkdirSync(REPORTS_DIR, { recursive: true });
    fs.appendFileSync(LOG_FILE, JSON.stringify(entry) + '\n', 'utf8');
  } catch (e) {
    console.warn('Failed to write sync log:', e.message);
  }
}

// ── Main ──────────────────────────────────────────────────────────────────

// ── Reports that support PDF output ─────────────────────────────────────
const PDF_SUPPORTED = new Set([
  'profit-and-loss.json', 'trial-balance.json', 'balance-sheet.json',
  'general-ledger.json', 'chart-of-accounts.json', 'tax-summary.json',
  'ar-aging.json', 'ap-aging.json', 'fixed-asset-schedule.json',
]);

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const forceRefresh = process.argv.includes('--force-refresh');
  const exportPdf = process.argv.includes('--pdf');

  if (exportPdf) console.log('── PDF MODE — reports will be saved as PDF ──\n');
  if (dryRun) console.log('── DRY RUN — no files will be written ──\n');

  // Resolve credentials
  const creds = resolveCreds();
  const auth = ZohoAuth.getInstance({ clientId: creds.clientId, clientSecret: creds.clientSecret, refreshToken: creds.refreshToken });
  const token = await auth.getToken();
  const orgId = creds.orgId;
  const BASE_URL = `https://www.zohoapis.com/books/v3`;

  console.log(`Reports dir: ${REPORTS_DIR}`);
  console.log(`Org ID:      ${orgId}`);
  console.log(`FY period:   ${FY_START} → ${FY_END}`);
  console.log(`Dry run:     ${dryRun}`);
  console.log();

  // Ensure reports dir exists
  fs.mkdirSync(REPORTS_DIR, { recursive: true });

  // Phase 1: Fetch chart of accounts first (needed for per-account GL resolution)
  console.log('── Phase 1: Fetching chart of accounts ──');
  const coaDef = REPORT_DEFS.find(d => d.file === 'chart-of-accounts.json');
  const coaUrl = `${BASE_URL}${coaDef.buildUrl(orgId)}`;
  const coaData = await zohoFetch(coaUrl, token);
  const accountMap = buildAccountMap(coaData);

  const coaContent = JSON.stringify(coaData, null, 2);
  const coaOld = readExisting(path.join(REPORTS_DIR, 'chart-of-accounts.json'));
  const coaChanged = coaOld !== null && coaOld !== coaContent;

  if (!dryRun) {
    fs.writeFileSync(path.join(REPORTS_DIR, 'chart-of-accounts.json'), coaContent, 'utf8');
  }

  appendLog({
    t: new Date().toISOString(),
    report: 'chart-of-accounts.json',
    changed: coaChanged,
    size_before: coaOld ? coaOld.length : 0,
    size_after: coaContent.length,
    hash_before: coaOld ? sha256(coaOld) : null,
    hash_after: sha256(coaContent)
  });

  console.log(`  chart-of-accounts.json  ${coaChanged ? '✓ UPDATED' : '— unchanged'}  (${coaContent.length.toLocaleString()} B)`);
  console.log(`  ${Object.keys(accountMap).length} accounts resolved`);
  console.log();

  // Phase 2: Fetch main reports (no account ID needed)
  console.log('── Phase 2: Main reports ──');
  const mainReports = REPORT_DEFS.filter(d => !d.nameHint && d.file !== 'chart-of-accounts.json');

  const results = [];
  let fullGlData = null;

  for (const def of mainReports) {
    const isPdf = exportPdf && PDF_SUPPORTED.has(def.file);
    const pdfUrl = isPdf ? `${BASE_URL}${def.buildUrl(orgId)}&accept=pdf` : null;
    const url = pdfUrl || `${BASE_URL}${def.buildUrl(orgId)}`;
    const data = await zohoFetch(url, token, isPdf);
    const fileName = isPdf ? def.file.replace(/\.json$/, '.pdf') : def.file;
    const filePath = path.join(REPORTS_DIR, fileName);
    const old = readExisting(filePath);

    let content, changed;

    if (isPdf) {
      content = typeof data === 'string' ? data : JSON.stringify(data);
      changed = old !== null && old !== content;
      if (!dryRun) fs.writeFileSync(filePath, content, 'utf8');
    } else {
      content = JSON.stringify(data, null, 2);
      changed = old !== null && old !== content;
      if (!dryRun) fs.writeFileSync(filePath, content, 'utf8');
      if (def.file === 'general-ledger.json') fullGlData = data;
    }

    appendLog({
      t: new Date().toISOString(),
      report: fileName,
      changed,
      size_before: old ? old.length : 0,
      size_after: content.length,
      hash_before: old ? sha256(old) : null,
      hash_after: sha256(content),
      format: isPdf ? 'pdf' : 'json'
    });

    const status = !old ? 'NEW' : changed ? '✓ UPDATED' : '— unchanged';
    console.log(`  ${fileName.padEnd(50)} ${status}  (${content.length.toLocaleString()} B)`);
    results.push({ file: fileName, changed, oldSize: old ? old.length : 0, newSize: content.length });
  }

  console.log();

  // Phase 3: Per-account GL reports (filtered from full GL — Zoho API does not support account_id filter)
  console.log('── Phase 3: Per-account GL reports ──');
  const glReports = REPORT_DEFS.filter(d => d.nameHint);

  for (const def of glReports) {
    const acctId = resolveAccountId(accountMap, def.nameHint);
    if (!acctId) {
      console.log(`  ${def.file.padEnd(50)} ⚠ SKIPPED  (no account match for "${def.nameHint}")`);
      appendLog({
        t: new Date().toISOString(),
        report: def.file,
        changed: false,
        skipped: true,
        reason: `No account match for "${def.nameHint}"`
      });
      continue;
    }

    const filtered = fullGlData ? filterGlByAccount(fullGlData, acctId) : { generalledger: [] };
    const content = JSON.stringify(filtered, null, 2);
    const filePath = path.join(REPORTS_DIR, def.file);
    const old = readExisting(filePath);
    const changed = old !== null && old !== content;

    if (!dryRun) {
      fs.writeFileSync(filePath, content, 'utf8');
    }

    appendLog({
      t: new Date().toISOString(),
      report: def.file,
      account_id: acctId,
      changed,
      size_before: old ? old.length : 0,
      size_after: content.length,
      hash_before: old ? sha256(old) : null,
      hash_after: sha256(content)
    });

    const status = !old ? 'NEW' : changed ? '✓ UPDATED' : '— unchanged';
    console.log(`  ${def.file.padEnd(50)} ${status}  (${acctId}, ${content.length.toLocaleString()} B)`);
    results.push({ file: def.file, changed, oldSize: old ? old.length : 0, newSize: content.length });
  }

  // ── Summary ──────────────────────────────────────────────────────────────
  const changedCount = results.filter(r => r.changed).length;
  const newCount = results.filter(r => r.oldSize === 0).length;
  const totalBytes = results.reduce((s, r) => s + r.newSize, 0);

  console.log();
  console.log(`── Summary ──`);
  console.log(`  Total reports:     ${results.length}`);
  console.log(`  Format:            ${exportPdf ? 'PDF' : 'JSON'}`);
  console.log(`  New:               ${newCount}`);
  console.log(`  Updated:           ${changedCount}`);
  console.log(`  Unchanged:         ${results.length - changedCount - newCount}`);
  console.log(`  Total data:        ${(totalBytes / 1024).toFixed(1)} KB`);
  console.log(`  API calls:         ${_callCount}`);
  console.log(`  Sync log:          ${LOG_FILE}`);

  if (dryRun) {
    console.log(`\n  Dry run complete — no files written.`);
  } else {
    const link = 'https://github.com/anomalyco/intersite-orchestrator/commit/????????';
    console.log(`\n  Rollback: git diff to see changes; git checkout <file> to revert a single file.`);
  }
}

main().catch(err => {
  console.error(`\nFATAL: ${err.message}`);
  process.exit(1);
});
