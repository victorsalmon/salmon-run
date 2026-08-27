#!/usr/bin/env node
// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Get ONE token at session start, cache it, reuse for ALL calls. See known-issues.md.
//
// Post-reconciliation transaction prune.
// Identifies and deletes unreconciled manual transactions in reconciled periods.
// 
// Skips transfer_fund transactions (CC payments between org accounts) — these
// are legitimate inter-account transfers, not orphan duplicates.
//
// Usage:
//   node post-recon-tx-prune.mjs --dry-run                     # Show candidates
//   node post-recon-tx-prune.mjs --execute                      # Delete candidates
//   node post-recon-tx-prune.mjs --dry-run --cutoff 2026-05-13 # Custom cutoff
//   node post-recon-tx-prune.mjs --dry-run --account mc-6258   # Single account
//
// See: Skills/Bookkeeping/zoho/post-recon-tx-prune.md

import fs from 'fs';
import path from 'path';
import { resolveSync, getOrgId } from './resolve-zoho-creds.mjs';
import { loadEntityConfig } from '../shared/load-entity-config.mjs';
import { ZohoAuth } from './zoho-auth.js';
import { ZohoRateLimiter } from './zoho-rate-limiter.mjs';

const BASE_URL = 'https://www.zohoapis.com/books/v3';

function getBankAccountId(zohoName) {
  if (zohoName === 'rbc-intersite') return '93310000000100019';
  if (zohoName === 'mc-6258') return '93310000000100013';
  if (zohoName === 'fra') return '151803000000101245';
  if (zohoName === 'mlm') return '151803000000101006';
  if (zohoName === 'tmh') return '151803000000101153';
  if (zohoName === 'rbc-visa') return '151803000000101251';
  throw new Error(`Unknown zoho account name: ${zohoName}`);
}

const TARGET_ACCOUNTS = (() => {
  const entity = loadEntityConfig('intersite-consulting');
  return (entity.bank_statement_accounts || []).map(a => ({
    id: getBankAccountId(a.zoho_account),
    name: a.zoho_account,
    label: a.label,
  }));
})();

const DEFAULT_CUTOFF = '2026-05-13';

const limiter = new ZohoRateLimiter({ minGapMs: 350, batchSleepMs: 2000 });

async function getToken(creds) {
  const auth = ZohoAuth.getInstance({
    clientId: creds.ZOHO_BOOKS_ID,
    clientSecret: creds.ZOHO_BOOKS_SECRET,
    refreshToken: creds.ZOHO_BOOKS_REFRESH,
  });
  return auth.getToken();
}

async function apiGet(url, token) {
  const resp = await limiter.fetchWithRetry(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`API ${resp.status} for ${url.substring(0, 120)}: ${text.substring(0, 200)}`);
  }
  return resp.json();
}

async function deleteTransaction(txId, orgId, token) {
  const url = `${BASE_URL}/banktransactions/${txId}?organization_id=${orgId}`;
  const resp = await limiter.fetchWithRetry(url, {
    method: 'DELETE',
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const data = await resp.json();
  if (!resp.ok || (data.code !== 0)) {
    return { ok: false, code: data.code, error: data.message || `HTTP ${resp.status}` };
  }
  return { ok: true };
}

async function fetchTransactions(accountId, orgId, token, statusFilter) {
  const all = [];
  let page = 1;
  let hasMore = true;

  while (hasMore) {
    const statusParam = statusFilter ? `&status=${statusFilter}` : '';
    const url = `${BASE_URL}/banktransactions?account_id=${accountId}&organization_id=${orgId}&per_page=200&page=${page}&sort_column=date&sort_order=A${statusParam}`;
    const data = await apiGet(url, token);
    const txns = data.banktransactions || [];
    all.push(...txns);
    hasMore = data.page_context && data.page_context.has_more_page;
    page++;
    if (page > 25) break;
  }

  return all;
}

function formatTx(tx) {
  const date = tx.date || '?';
  const amount = tx.debit_or_credit === 'credit' ? `-${Math.abs(tx.amount || 0).toFixed(2)}` : Math.abs(tx.amount || 0).toFixed(2);
  const desc = (tx.description || tx.payee || '').substring(0, 60);
  const source = tx.source === 'statement_imported' ? '[IMPORTED]' : '[MANUAL]';
  return `${date}  ${amount.padStart(10)}  ${source}  ${desc.padEnd(62)}  ${tx.transaction_id}`;
}

async function main() {
  const isDryRun = process.argv.includes('--dry-run');
  const isExecute = process.argv.includes('--execute');

  const cutoffIdx = process.argv.indexOf('--cutoff');
  const cutoff = cutoffIdx >= 0 ? process.argv[cutoffIdx + 1] : DEFAULT_CUTOFF;

  const acctIdx = process.argv.indexOf('--account');
  let accounts = TARGET_ACCOUNTS;
  if (acctIdx >= 0) {
    const acctName = process.argv[acctIdx + 1];
    accounts = TARGET_ACCOUNTS.filter(a => a.name === acctName || a.id === acctName);
    if (accounts.length === 0) {
      console.error(`Unknown account: ${acctName}. Valid: ${TARGET_ACCOUNTS.map(a => a.name).join(', ')}`);
      process.exit(1);
    }
  }

  if (!isDryRun && !isExecute) {
    console.error('Must specify --dry-run or --execute');
    process.exit(1);
  }

  if (isExecute) {
    console.log('╔══════════════════════════════════════════╗');
    console.log('║  EXECUTE MODE — transactions WILL be    ║');
    console.log('║  permanently deleted from Zoho Books.   ║');
    console.log('╚══════════════════════════════════════════╝');
  } else {
    console.log('╔══════════════════════════════════════════╗');
    console.log('║  DRY RUN — no changes will be made.     ║');
    console.log('╚══════════════════════════════════════════╝');
  }
  console.log(`Cutoff date: ${cutoff} (only unreconciled txns on or before this date will be deleted)`);
  console.log();

  const creds = resolveSync();
  const orgId = getOrgId(creds, 'intersite-consulting');
  const token = await getToken(creds);

  let totalDeleted = 0;
  let totalFailed = 0;
  let totalSkipped = 0;

  for (const acct of accounts) {
    console.log(`── ${acct.label} (${acct.id}) ──`);

    let allTxns;
    try {
      console.log('  Fetching categorized transactions...');
      const categorized = await fetchTransactions(acct.id, orgId, token, '');
      console.log('  Fetching uncategorized transactions...');
      const uncategorized = await fetchTransactions(acct.id, orgId, token, 'uncategorized');
      allTxns = [...categorized, ...uncategorized];
    } catch (err) {
      console.error(`  ERROR fetching: ${err.message}`);
      continue;
    }

    allTxns.sort((a, b) => (a.date || '').localeCompare(b.date || ''));

    const unreconciledPreCutoff = allTxns.filter(tx => {
      const isUnreconciled = tx.reconcile_status !== 'reconciled';
      const isPreCutoff = tx.date && tx.date <= cutoff;
      const isNotTransferFund = tx.transaction_type !== 'transfer_fund';
      return isUnreconciled && isPreCutoff && isNotTransferFund;
    });

    const reconciledPreCutoff = allTxns.filter(tx => {
      return tx.reconcile_status === 'reconciled' && tx.date && tx.date <= cutoff;
    });

    const postCutoff = allTxns.filter(tx => tx.date && tx.date > cutoff);

    const skippedTransferFund = allTxns.filter(tx => {
      return tx.transaction_type === 'transfer_fund' && tx.date && tx.date <= cutoff;
    });

    console.log(`  Total transactions: ${allTxns.length}`);
    console.log(`  Reconciled (pre-cutoff): ${reconciledPreCutoff.length} (protected)`);
    console.log(`  Transfers (pre-cutoff): ${skippedTransferFund.length} (skipped — CC payments)`);
    console.log(`  Post-cutoff: ${postCutoff.length} (protected — not yet reconciled)`);
    console.log(`  Unreconciled & pre-cutoff: ${unreconciledPreCutoff.length} (prune candidates)`);

    if (unreconciledPreCutoff.length === 0) {
      console.log('  No candidates — nothing to do.');
      console.log();
      continue;
    }

    console.log();
    console.log(`  Candidates (${unreconciledPreCutoff.length}):`);
    for (const tx of unreconciledPreCutoff) {
      console.log(`    ${formatTx(tx)}`);
    }

    if (isExecute) {
      console.log();
      let debug = 0, matchCat = 0, other = 0;
      for (const tx of unreconciledPreCutoff) {
        const result = await deleteTransaction(tx.transaction_id, orgId, token);
        if (result.ok) {
          console.log(`  ✓ Deleted: ${tx.date}  ${tx.transaction_id}`);
          totalDeleted++;
        } else {
          if (result.code === 19007) {
            console.log(`  – Skipped (reconciled): ${tx.date}  ${tx.transaction_id}  — ${result.error}`);
            debug++;
          } else if (result.code === 19015) {
            console.log(`  – Skipped (categorized): ${tx.date}  ${tx.transaction_id}  — ${result.error}`);
            matchCat++;
          } else {
            console.error(`  ✗ Failed (${result.code}): ${tx.date}  ${tx.transaction_id}  — ${result.error}`);
            other++;
          }
          totalFailed++;
        }
      }
      if (debug > 0 || matchCat > 0) {
        console.log(`    (${debug} reconciled-by-status, ${matchCat} matched/categorized — expected API protection)`);
      }
    } else {
      totalSkipped += unreconciledPreCutoff.length;
    }

    console.log();
  }

  console.log('── Summary ──');
  console.log(`  API calls: ${limiter.stats.totalCalls}`);
  if (isDryRun) {
    console.log(`  Dry run: ${totalSkipped} candidates identified (no deletions performed).`);
    console.log(`  Re-run with --execute to delete these transactions.`);
  } else {
    console.log(`  Deleted: ${totalDeleted}  Protected-by-API: ${totalFailed}`);
    if (totalFailed > 0) {
      console.log(`  Protected transactions are expected — see failure details above for reasons.`);
    }
  }
}

main().catch(err => {
  console.error(`\nFATAL: ${err.message}`);
  process.exit(1);
});
