#!/usr/bin/env node
// PRP Stage 7d — Cloud Balance Forward Verification
// Exports Zoho bank transactions with Plaid/manual markers and running balance.
// Builds a reconciliation table by period and compares against TAS.
//
// Used by: Skills/Bookkeeping/books/reconciliation/prp-stage7-cloud-alignment.md § Sub-stage 7d
//
// Usage:
//   node verify-zoho-balance.mjs                          # room-rentals
//   node verify-zoho-balance.mjs --entity intersite-consulting

import { ZohoAuth } from './zoho-auth.js';
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
const require = createRequire(import.meta.url);
const { parseArgs, loadEntityConfig, sleep, parseDate } = require('../shared/lib/zoho-common.js');
const { fetchWithAudit } = require('../shared/lib/audit-logger.mjs');

const args = parseArgs();
const entity = args.entity || 'room-rentals';
const { config, ec } = loadEntityConfig(entity);
const ORG_ID = ec.org_id;
const BOOKS_ROOT = path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity);

function fmt(n) { return '$' + Number(n || 0).toFixed(2); }

// ── Period definitions from reconciliation-periods.md ──
const PERIODS = {
  'RBC-FRA 5172549': [
    { label: 'Dec19-Jan21', start: '2025-12-19', end: '2026-01-21', closing: 1702.25 },
    { label: 'Jan21-Feb20', start: '2026-01-21', end: '2026-02-20', closing: 4121.72 },
    { label: 'Feb20-Mar20', start: '2026-02-20', end: '2026-03-20', closing: 1834.50 },
    { label: 'Mar20-Apr21', start: '2026-03-20', end: '2026-04-21', closing: 2890.08 },
    { label: 'Apr21-May21', start: '2026-04-21', end: '2026-05-21', closing: 4115.75 },
  ],
  'TD-MLM 6467010': [
    { label: 'Nov28-Dec31', start: '2025-11-28', end: '2025-12-31', closing: 4378.25 },
    { label: 'Jan30-Feb27', start: '2026-01-30', end: '2026-02-27', closing: 3159.02 },
    { label: 'Feb27-Mar31', start: '2026-02-27', end: '2026-03-31', closing: 5090.89 },
    { label: 'Mar31-Apr30', start: '2026-03-31', end: '2026-04-30', closing: 4247.06 },
    { label: 'Apr30-May29', start: '2026-04-30', end: '2026-05-29', closing: 4496.21 },
  ],
  'SCOTIA-TMH 406000697486': [
    { label: 'Dec21-Jan20', start: '2025-12-21', end: '2026-01-20', closing: 2875.72 },
    { label: 'Jan21-Feb20', start: '2026-01-21', end: '2026-02-20', closing: 4143.80 },
    { label: 'Feb21-Mar20', start: '2026-02-21', end: '2026-03-20', closing: 5460.99 },
    { label: 'Mar21-Apr20', start: '2026-03-21', end: '2026-04-20', closing: 6920.10 },
    { label: 'Apr21-May20', start: '2026-04-21', end: '2026-05-20', closing: 5642.10 },
  ],
  'RBC-FRA-6679 Visa': [
    { label: 'Dec10-Jan09', start: '2025-12-10', end: '2026-01-09', closing: 81.28 },
    { label: 'Jan10-Feb09', start: '2026-01-10', end: '2026-02-09', closing: 188.12 },
    { label: 'Feb10-Mar09', start: '2026-02-10', end: '2026-03-09', closing: 64.25 },
    { label: 'Mar10-Apr09', start: '2026-03-10', end: '2026-04-09', closing: 2.11 },
    { label: 'Apr10-May11', start: '2026-04-10', end: '2026-05-11', closing: 55.95 },
    { label: 'May12-Jun09', start: '2026-05-12', end: '2026-06-09', closing: 180.32 },
  ],
};

// Account label -> Zoho account_id mapping
const ACCOUNT_IDS = {
  'RBC-FRA 5172549': '151803000000101245',
  'RBC-FRA-6679 Visa': '151803000000101251',
  'SCOTIA-TMH 406000697486': '151803000000101153',
  'TD-MLM 6467010': '151803000000101006',
};

async function fetchBankTxnsWithStatus(auth, acctId, status) {
  let page = 1, all = [], hasMore = true;
  while (hasMore && page <= 50) {
    let url = `https://www.zohoapis.com/books/v3/banktransactions?account_id=${acctId}&organization_id=${ORG_ID}&per_page=200&page=${page}&sort_column=date&sort_order=A`;
    if (status) url += `&status=${status}`;
    const resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:banktransactions:export' });
    const data = resp.data;
    if (data.code !== 0) throw new Error(`Bank txns page ${page}: ${data.message}`);
    all = all.concat(data.banktransactions || []);
    hasMore = data.page_context?.has_more_page || false;
    page++;
    await sleep(400);
  }
  return all;
}

async function fetchAllBankTxns(auth, acctId) {
  const [categorized, uncategorized] = await Promise.all([
    fetchBankTxnsWithStatus(auth, acctId, ''),
    fetchBankTxnsWithStatus(auth, acctId, 'uncategorized'),
  ]);
  const seen = new Set();
  const merged = [];
  for (const txn of [...categorized, ...uncategorized]) {
    if (!seen.has(txn.transaction_id)) {
      seen.add(txn.transaction_id);
      merged.push(txn);
    }
  }
  return merged.sort((a, b) => (a.date || a.transaction_date || '').localeCompare(b.date || b.transaction_date || ''));
}

async function main() {
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();

  console.log(`# PRP Stage 7d: Cloud Balance Forward Verification — ${entity}`);
  console.log(`Generated: ${new Date().toISOString().split('T')[0]}\n`);

  for (const [label, acctId] of Object.entries(ACCOUNT_IDS)) {
    const periods = PERIODS[label];
    if (!periods) { console.log(`## ${label}\nNo period definitions found.\n`); continue; }

    console.log(`## ${label}`);
    console.log(`Zoho Account ID: ${acctId}`);

    // Fetch all Zoho bank transactions
    const txns = await fetchAllBankTxns(auth, acctId);
    console.log(`Total transactions: ${txns.length}`);

    // Sort by date ascending
    txns.sort((a, b) => (a.date || a.transaction_date || '').localeCompare(b.date || b.transaction_date || ''));

    // Categorize: imported (Plaid) vs manual
    const plaid = [], manual = [];
    for (const t of txns) {
      const source = t.source || '';
      const status = t.status || '';
      const importedId = t.imported_transaction_id || '';
      if (importedId || source === 'imported' || source === 'importer' || status === 'imported') {
        plaid.push(t);
      } else {
        manual.push(t);
      }
    }
    console.log(`  Plaid-synced: ${plaid.length}`);
    console.log(`  Manual: ${manual.length}`);

    // Get running balance from last transaction
    let currentBalance = 0;
    if (txns.length > 0) {
      const last = txns[txns.length - 1];
      currentBalance = parseFloat(last.running_balance || last.running_balance_formatted || 0);
      if (isNaN(currentBalance)) currentBalance = 0;
    }
    console.log(`  Current running balance (from last txn): ${fmt(currentBalance)}\n`);

    // Build period table
    const table = [];
    let periodStartBalance = 0;
    let prevEnd = null;

    for (let i = 0; i < periods.length; i++) {
      const p = periods[i];
      const periodTxns = txns.filter(t => {
        const td = t.date || t.transaction_date || '';
        if (i === 0) return td >= p.start && td <= p.end;
        return td > prevEnd && td <= p.end;
      });

      let netDebits = 0, netCredits = 0;
      for (const t of periodTxns) {
        const amt = parseFloat(t.amount || 0);
        if (t.debit_or_credit === 'debit') netDebits += amt;
        else netCredits += amt;
      }
      const netFlow = netCredits - netDebits;

      if (i === 0) {
        // Work backwards: opening = closing - netFlow
        periodStartBalance = p.closing - netFlow;
      }

      const zohoClosing = periodStartBalance + netFlow;
      const diff = zohoClosing - p.closing;

      table.push({
        period: p.label,
        start: p.start,
        end: p.end,
        opening: periodStartBalance,
        plaidCount: periodTxns.filter(t => plaid.includes(t)).length,
        manualCount: periodTxns.filter(t => manual.includes(t)).length,
        netFlow,
        zohoClosing,
        stmtClosing: p.closing,
        diff,
        status: Math.abs(diff) <= 0.02 ? '✅' : Math.abs(diff) <= 50 ? '⚠' : '❌',
      });

      periodStartBalance = p.closing;
      prevEnd = p.end;
    }

    // Print table
    console.log('| Period | Opening | Plaid | Manual | Net Flow | Zoho Close | Stmt Close | Diff | Status |');
    console.log('|--------|---------|-------|--------|----------|------------|------------|------|--------|');
    for (const r of table) {
      console.log(`| ${r.period} | ${fmt(r.opening)} | ${r.plaidCount} | ${r.manualCount} | ${fmt(r.netFlow)} | ${fmt(r.zohoClosing)} | ${fmt(r.stmtClosing)} | ${fmt(r.diff)} | ${r.status} |`);
    }

    // Summary
    const ok = table.filter(r => r.status === '✅').length;
    const warn = table.filter(r => r.status === '⚠').length;
    const fail = table.filter(r => r.status === '❌').length;
    console.log(`\n${ok} ✅, ${warn} ⚠, ${fail} ❌ of ${table.length} periods\n`);
  }
}

main().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
