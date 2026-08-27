#!/usr/bin/env node
// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Get ONE token at session start, cache it, reuse for ALL calls. See known-issues.md.

import fs from 'fs';
import os from 'os';
import path from 'path';
import { fetchWithAudit } from '../shared/lib/audit-logger.mjs';
import { loadEntityConfig, getEntityAccounts, getOrgId } from '../shared/load-entity-config.mjs';
import { resolveSync } from './resolve-zoho-creds.mjs';
import { ZohoAuth } from './zoho-auth.js';
import { ZohoRateLimiter } from './zoho-rate-limiter.mjs';

const BOOKS_DIR = path.resolve(process.env.USERPROFILE || os.homedir(), 'intersite-docs', 'Taxes and Bookkeeping');

const limiter = new ZohoRateLimiter({ minGapMs: 350, batchSleepMs: 2000 });

function resolveCredsOrThrow() {
  const creds = resolveSync();
  const missing = [];
  if (!creds || !creds.ZOHO_BOOKS_ID) missing.push('ZOHO_BOOKS_ID');
  if (!creds || !creds.ZOHO_BOOKS_SECRET) missing.push('ZOHO_BOOKS_SECRET');
  if (!creds || !creds.ZOHO_BOOKS_REFRESH) missing.push('ZOHO_BOOKS_REFRESH');
  if (missing.length > 0) {
    throw new Error(
      `Failed to resolve Zoho credentials from any source (Docker proxy, AWS Secrets Manager). Missing: ${missing.join(', ')}`
    );
  }
  return creds;
}

async function zohoFetch(url, token) {
  const resp = await fetchWithAudit(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });

  if (resp.status === 429) {
    const maxRetries = 3;
    for (let attempt = 0; attempt < maxRetries; attempt++) {
      const delay = Math.pow(2, attempt) * 1000;
      console.warn(`  Rate limited (429) — retry ${attempt + 1}/${maxRetries} after ${delay}ms`);
      await new Promise(r => setTimeout(r, delay));
      await limiter.batchWait();
      const retryResp = await fetchWithAudit(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
      if (retryResp.ok) return retryResp.data;
      if (retryResp.status !== 429) break;
    }
  }

  if (!resp.ok) {
    throw new Error(`API ${resp.status} for ${url.substring(0, 100)}: ${JSON.stringify(resp.data).substring(0, 200)}`);
  }

  return resp.data;
}

function escapeCsv(val) {
  if (val == null) return '';
  const s = String(val);
  if (s.includes(',') || s.includes('"') || s.includes('\n')) {
    return `"${s.replace(/"/g, '""')}"`;
  }
  return s;
}

function formatAmount(n) {
  return Math.abs(parseFloat(n || 0)).toFixed(2);
}

async function fetchTransactionsWithStatus(baseUrl, token, accountId, orgId, status) {
  const all = [];
  let page = 1;
  let hasMore = true;

  while (hasMore) {
    let url = `${baseUrl}/banktransactions?account_id=${accountId}&organization_id=${orgId}&per_page=200&page=${page}&sort_column=date&sort_order=D`;
    if (status) url += `&status=${status}`;
    const data = await zohoFetch(url, token);
    const txns = data.banktransactions || [];
    all.push(...txns);
    hasMore = data.page_context && data.page_context.has_more_page;
    page++;
    if (page > 25) break;
  }

  return all;
}

async function fetchAllTransactions(baseUrl, token, accountId, orgId) {
  const [categorized, uncategorized] = await Promise.all([
    fetchTransactionsWithStatus(baseUrl, token, accountId, orgId, ''),
    fetchTransactionsWithStatus(baseUrl, token, accountId, orgId, 'uncategorized'),
  ]);
  const seen = new Set();
  const merged = [];
  for (const txn of [...categorized, ...uncategorized]) {
    if (!seen.has(txn.transaction_id)) {
      seen.add(txn.transaction_id);
      merged.push(txn);
    }
  }
  return merged.sort((a, b) => new Date(b.date || 0) - new Date(a.date || 0));
}

function transactionsToCsv(txns, accountLabel) {
  const header = '# Source: Zoho Books API (Plaid-synced transactions)\n' +
    `# Account: ${accountLabel}\n` +
    `# Generated: ${new Date().toISOString().split('T')[0]}\n` +
    `# Transactions: ${txns.length}\n` +
    '# Format: date,payee,description,debit_or_credit,amount,zoho_transaction_id,transaction_type,zoho_category,receipt_filename\n' +
    'date,payee,description,debit_or_credit,amount,zoho_transaction_id,transaction_type,zoho_category,receipt_filename';

  const rows = txns.map(t => {
    const date = t.date || '';
    const payee = t.payee || t.reference_number || t.offset_account_name || '';
    const description = t.description || t.payee || t.reference_number || t.offset_account_name || '';
    const debitOrCredit = t.debit_or_credit || (parseFloat(t.amount || 0) >= 0 ? 'debit' : 'credit');
    const absAmount = formatAmount(t.amount);
    const txId = t.transaction_id || '';
    const txType = t.transaction_type || '';
    const category = t.offset_account_name || t.account_name || '';
    return [date, payee, description, debitOrCredit, absAmount, txId, txType, category, '']
      .map(escapeCsv).join(',');
  });

  return [header, ...rows].join('\n');
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const entitySlug = process.argv.includes('--entity')
    ? process.argv[process.argv.indexOf('--entity') + 1]
    : null;

  if (dryRun) console.log('── DRY RUN — no files will be written ──\n');

  const creds = resolveCredsOrThrow();
  const auth = ZohoAuth.getInstance({ clientId: creds.ZOHO_BOOKS_ID, clientSecret: creds.ZOHO_BOOKS_SECRET, refreshToken: creds.ZOHO_BOOKS_REFRESH });
  const token = await auth.getToken();
  const BASE_URL = 'https://www.zohoapis.com/books/v3';

  const slugsToProcess = entitySlug ? [entitySlug] : ['intersite-consulting', 'room-rentals'];

  for (const slug of slugsToProcess) {
    const entity = loadEntityConfig(slug);
    const orgId = getOrgId(slug);
    const bankStatementsDir = slug === 'room-rentals'
      ? path.resolve(BOOKS_DIR, slug, '2026 Bank Statements')
      : path.resolve(BOOKS_DIR, slug, '2026 Filing', '2026 Bank Statements');

    console.log(`── ${slug} (org ${orgId}) ──`);

    const cutoffDate = entity.cutoff_date;
    const accounts = getEntityAccounts(slug);

    for (const acct of accounts) {
      const entityDir = path.resolve(bankStatementsDir, acct.folder);
      console.log(`  Fetching ${acct.label} (${acct.zoho_account})...`);

      const zohoAcctId = acct.zoho_account === 'rbc-intersite' ? '93310000000100019'
        : acct.zoho_account === 'mc-6258' ? '93310000000100013'
        : acct.zoho_account === 'fra' ? '151803000000101245'
        : acct.zoho_account === 'mlm' ? '151803000000101006'
        : acct.zoho_account === 'tmh' ? '151803000000101153'
        : acct.zoho_account === 'rbc-visa' ? '151803000000101251'
        : null;

      let txns;
      try {
        txns = await fetchAllTransactions(BASE_URL, token, zohoAcctId, orgId);
      } catch (err) {
        console.error(`  ERROR fetching ${acct.label}: ${err.message}`);
        continue;
      }

      const csvContent = transactionsToCsv(txns, acct.label);
      const [cy, cm, cd] = cutoffDate.split('-').map(Number);
      const nextDay = new Date(cy, cm - 1, cd + 1);
      const startDay = `${nextDay.getFullYear()}.${String(nextDay.getMonth() + 1).padStart(2, '0')}.${String(nextDay.getDate()).padStart(2, '0')}`;
      const datePrefix = `${startDay}-Present`;
      const csvFileName = `${datePrefix} - ${acct.label} - Zoho.csv`;
      const csvPath = path.resolve(entityDir, csvFileName);

      if (!dryRun) {
        fs.mkdirSync(entityDir, { recursive: true });
        fs.writeFileSync(csvPath, csvContent, 'utf8');
      }

      console.log(`  ${txns.length} transactions → ${csvFileName}${dryRun ? ' (dry-run)' : ''}`);
    }

    console.log();
  }

  console.log(`── Summary ──`);
  console.log(`  API calls: ${limiter.stats.totalCalls}`);
  if (dryRun) {
    console.log(`  Dry run complete — no files written.`);
  }
}

main().catch(err => {
  console.error(`\nFATAL: ${err.message}`);
  process.exit(1);
});
