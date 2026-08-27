#!/usr/bin/env node
// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Get ONE token at session start, cache it, reuse for ALL calls. See known-issues.md.
// Reclassify Zoho expense transactions to a different account via PUT /expenses.
// Usage:
//   node reclassify-to-9150.mjs                                           (uses built-in transaction list)
//   node reclassify-to-9150.mjs --csv transacts.csv --target "account_id"  (bulk from CSV)
//   node reclassify-to-9150.mjs --find-account "9150|tech"                 (search for account)
//
// CSV format: date,amount,description,expense_id
// Target account can be account_id or a GIFI code (e.g. "9150")

import fs from 'fs';
import { ZohoAuth } from './zoho-auth.js';

const ORG_ID = '925048093';

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--csv' && i + 1 < args.length) opts.csv = args[++i];
    else if (args[i] === '--target' && i + 1 < args.length) opts.target = args[++i];
    else if (args[i] === '--find-account' && i + 1 < args.length) opts.findAccount = args[++i];
    else if (args[i] === '--help') opts.help = true;
  }
  return opts;
}

// Transaction list from the 2026-06-30 reclass session: Office → 9150 Tech repair
const BUILTIN_TRANSACTIONS = [
  { date: '2025-10-24', amount: 19.70, desc: 'HDMI cable', expense_id: '93310000000211347' },
  { date: '2025-08-01', amount: 17.91, desc: 'Surge protector', expense_id: '93310000000216431' },
  { date: '2025-11-27', amount: 40.92, desc: 'Power bank', expense_id: '93310000000222440' },
  { date: '2026-02-07', amount: 35.21, desc: 'LED desk lamp', expense_id: '93310000000206418' },
  { date: '2026-03-22', amount: 30.23, desc: 'UGREEN cables', expense_id: '93310000000220343' },
  { date: '2025-11-27', amount: 64.95, desc: 'Computer accessory', expense_id: '93310000000202440' },
  { date: '2025-11-21', amount: 42.99, desc: 'Feet for electronics', expense_id: '93310000000209467' },
];

async function getAuthHeaders() {
  return ZohoAuth.getAuthHeadersStatic();
}

async function zohoGet(headers, path) {
  const url = `https://www.zohoapis.com/books/v3${path}${path.includes('?') ? '&' : '?'}organization_id=${ORG_ID}`;
  console.log(`  GET ${path}`);
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`GET ${path} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function zohoPut(headers, path, body) {
  const url = `https://www.zohoapis.com/books/v3${path}${path.includes('?') ? '&' : '?'}organization_id=${ORG_ID}`;
  console.log(`  PUT ${path}`);
  const res = await fetch(url, { method: 'PUT', headers, body: JSON.stringify(body) });
  if (!res.ok) throw new Error(`PUT ${path} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function resolveTargetAccount(headers, targetOpt) {
  const coa = await zohoGet(headers, '/chartofaccounts?per_page=200');
  const accounts = coa.chartofaccounts || [];

  if (targetOpt) {
    // Try by GIFI code first (numeric)
    if (/^\d{4}$/.test(targetOpt)) {
      const byCode = accounts.find(a => a.account_code === targetOpt);
      if (byCode) return byCode;
    }
    // Try by account_id
    const byId = accounts.find(a => a.account_id === targetOpt);
    if (byId) return byId;
    // Try by name match
    const byName = accounts.find(a => a.account_name.toLowerCase().includes(targetOpt.toLowerCase()));
    if (byName) return byName;
    throw new Error(`Target account not found: ${targetOpt}`);
  }

  // Default: look for 9150
  let target = accounts.find(a =>
    a.account_name.includes('9150') ||
    a.account_name.toLowerCase().includes('tech repair')
  );
  if (!target) {
    target = accounts.find(a => a.account_id === '93310000000582161');
  }
  if (target) return target;

  // Fallback: create
  const createBody = { account_name: '[9150] Tech repair, support, subscriptions, peripherals', account_type: 'expense', account_code: '9150', is_user_created: true, is_active: true };
  const createUrl = `https://www.zohoapis.com/books/v3/chartofaccounts?organization_id=${ORG_ID}`;
  const createRes = await fetch(createUrl, { method: 'POST', headers, body: JSON.stringify(createBody) });
  if (!createRes.ok) throw new Error(`Create account failed: ${createRes.status}`);
  const created = await createRes.json();
  return created.chartofaccount || created.account;
}

async function reclassifyExpense(headers, expenseId, newAccountId, label) {
  const expenseDetail = await zohoGet(headers, `/expenses/${expenseId}`);
  const expense = expenseDetail.expense || expenseDetail;
  const oldAcct = `${expense.account_name} (${expense.account_id})`;

  if (expense.account_id === newAccountId) return { ok: true, skipped: true, oldAcct };

  const payload = {
    account_id: newAccountId,
    paid_through_account_id: expense.paid_through_account_id,
    vendor_id: expense.vendor_id || '',
    currency_id: expense.currency_id,
    exchange_rate: expense.exchange_rate || 1,
    amount: expense.amount || expense.total || 0,
    date: expense.date,
    description: label || expense.description,
    is_billable: expense.is_billable || false,
    is_inclusive_tax: expense.is_inclusive_tax || false,
    line_items: (expense.line_items || []).map(item => ({ ...item, account_id: newAccountId }))
  };
  if (!payload.line_items.length) {
    payload.line_items = [{ account_id: newAccountId, amount: payload.amount, description: payload.description }];
  }

  await zohoPut(headers, `/expenses/${expenseId}`, payload);
  return { ok: true, skipped: false, oldAcct };
}

function loadTransactionsFromCsv(csvPath) {
  const raw = fs.readFileSync(csvPath, 'utf8');
  const lines = raw.trim().split('\n').filter(l => l.trim() && !l.startsWith('#'));
  return lines.map(line => {
    const parts = line.split(',');
    return { date: parts[0].trim(), amount: parseFloat(parts[1]), desc: (parts[2] || '').trim(), expense_id: (parts[3] || '').trim() };
  }).filter(t => t.expense_id);
}

async function findAccountsMatching(headers, pattern) {
  const coa = await zohoGet(headers, '/chartofaccounts?per_page=200');
  const re = new RegExp(pattern, 'i');
  return (coa.chartofaccounts || []).filter(a => re.test(a.account_name) || re.test(a.account_code || ''));
}

async function main() {
  const opts = parseArgs();

  if (opts.help) {
    console.log('Usage:');
    console.log('  node reclassify-to-9150.mjs [--csv <file>] [--target <gifi|account_id|name>] [--find-account <pattern>]');
    console.log('');
    console.log('  --csv <file>         CSV with columns: date,amount,description,expense_id');
    console.log('  --target <gifi|id>   Target account (GIFI code like "9150", account_id, or name substring)');
    console.log('  --find-account <re>  Search chart of accounts for matching names');
    console.log('');
    console.log('  Without arguments, reclassifies the built-in transaction list to GIFI 9150.');
    process.exit(0);
  }

  const headers = await getAuthHeaders();

  // --find-account mode
  if (opts.findAccount) {
    const matches = await findAccountsMatching(headers, opts.findAccount);
    console.log(`Matching accounts (${matches.length}):`);
    matches.forEach(a => console.log(`  ${a.account_id}  ${a.account_name}  GIFI:${a.account_code || '-'}`));
    return;
  }

  const targetAccount = await resolveTargetAccount(headers, opts.target);
  const newAccountId = targetAccount.account_id;
  console.log(`Target: ${targetAccount.account_name} (${newAccountId})\n`);

  const transactions = opts.csv ? loadTransactionsFromCsv(opts.csv) : BUILTIN_TRANSACTIONS;
  console.log(`Processing ${transactions.length} transactions...\n`);

  let success = 0, skipped = 0, failed = 0;
  for (const tx of transactions) {
    process.stdout.write(`  ${tx.date}  $${tx.amount.toFixed(2)}  ${tx.desc.substring(0, 30)}... `);
    try {
      const result = await reclassifyExpense(headers, tx.expense_id, newAccountId, tx.desc);
      if (result.skipped) { console.log(`skipped (already ${result.oldAcct})`); skipped++; }
      else { console.log(`✓ ${result.oldAcct} → ${targetAccount.account_name}`); success++; }
    } catch (err) {
      console.log(`✗ ${err.message.substring(0, 120)}`);
      failed++;
    }
  }

  console.log(`\nDone: ${success} reclassified, ${skipped} skipped, ${failed} failed`);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
