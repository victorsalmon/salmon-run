#!/usr/bin/env node
// PRP Stage 7c — Sync TAS categories to Zoho expenses.
// For each TAS row with a matched zoho_expense_id, fetches the Zoho expense,
// compares its account_id to the TAS category mapping, and updates if different.
//
// Used by: Skills/Bookkeeping/books/reconciliation/prp-stage7-cloud-alignment.md § Sub-stage 7c
//
// Usage:
//   node sync-tas-categories.mjs                              # room-rentals
//   node sync-tas-categories.mjs --entity intersite-consulting
//   node sync-tas-categories.mjs --dry-run

import { ZohoAuth } from './zoho-auth.js';
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
const require = createRequire(import.meta.url);
const { parseArgs, loadEntityConfig, sleep } = require('./lib/zoho-common.js');
const { fetchWithAudit } = require('./lib/audit-logger.mjs');

const args = parseArgs();
const entity = args.entity || 'room-rentals';
const dryRun = process.argv.includes('--dry-run');

const { config, ec } = loadEntityConfig(entity);
const ORG_ID = ec.org_id;
const BOOKS_ROOT = path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity);
const TAS_PATH = path.join(BOOKS_ROOT, 'TAS-2026.csv');

// ── TAS category → Zoho account_id mapping for room-rentals ──
// From cloud-books-entities.json room-rentals.categories
const CATEGORY_MAP = {
  'Advertising': '151803000000000403',
  'Automobile Expense': '151803000000000424',
  'Bad Debt': '151803000000000439',
  'Bank Fee': '151803000000000409',
  'Bank Fees and Charges': '151803000000000409',
  'Consultant': '151803000000000454',
  'Credit Card Charges': '151803000000000412',
  'Credit Card Payment': '151803000000000412',
  'Damage Deposit': '151803000000197002',
  'Expense': '151803000000000460',
  'Insurance': '151803000000000412',
  'Internet': '151803000000000427',
  'IT Internet': '151803000000000427',
  'Janitorial': '151803000000000433',
  'Loan Payment': '151803000000000439',
  'Management Fee': '151803000000000454',
  'Meals': '151803000000000448',
  'Mortgage': '151803000000000460',
  'Office Supplies': '151803000000000400',
  'Office Supplies and General Expenses': '151803000000000400',
  'Other': '151803000000000460',
  'Other Expenses': '151803000000000460',
  'Other Income': '151803000000000460',
  'Owner Funding': '151803000000000460',
  'Postage': '151803000000000436',
  'Printing': '151803000000000442',
  'Professional Services': '151803000000000454',
  'Property Tax': '151803000000000460',
  'Rent': '151803000000000430',
  'Rent Revenue': '151803000000000430',
  'Repairs': '151803000000000457',
  'Repairs and Maintenance': '151803000000000457',
  'Service Fee': '151803000000000448',
  'Software and IT Expenses': '151803000000000427',
  'Strata Fees': '151803000000000460',
  'Subscription': '151803000000000427',
  'Supplies': '151803000000000400',
  'Telephone Expense': '151803000000000421',
  'Transfer Out': '151803000000000460',
  'Travel': '151803000000000418',
  'Utility': '151803000000245013',
  'Utilities': '151803000000245013',
  'Vehicle/Other': '151803000000000424',
};

function parseTasCsv(text) {
  const lines = text.trim().split('\n').filter(l => l.trim() && !l.startsWith('#'));
  if (lines.length === 0) return [];
  const header = lines[0].split(',').map(h => h.replace(/^"|"$/g, ''));
  return lines.slice(1).map(l => {
    const vals = [];
    let cur = '', inQ = false;
    for (const ch of l) {
      if (ch === '"') { inQ = !inQ; continue; }
      if (ch === ',' && !inQ) { vals.push(cur.trim()); cur = ''; continue; }
      cur += ch;
    }
    vals.push(cur.trim());
    const obj = {};
    header.forEach((h, i) => obj[h] = (vals[i] || ''));
    return obj;
  });
}

async function fetchExpense(auth, expenseId) {
  const url = `https://www.zohoapis.com/books/v3/expenses/${expenseId}?organization_id=${ORG_ID}`;
  const resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:expense:fetch' });
  if (!resp.ok) throw new Error(`Fetch expense ${expenseId}: HTTP ${resp.status}`);
  const data = resp.data;
  if (data.code !== 0) throw new Error(`Fetch expense ${expenseId}: Zoho code ${data.code}`);
  return data.expense;
}

async function updateExpenseCategory(auth, expenseId, accountId) {
  const url = `https://www.zohoapis.com/books/v3/expenses/${expenseId}?organization_id=${ORG_ID}`;
  const body = JSON.stringify({ account_id: accountId });
  const resp = await fetchWithAudit(url, {
    method: 'PUT',
    headers: { ...auth.headers, 'Content-Type': 'application/json' },
    body
  }, { domain: 'Bookkeeper', action: 'zoho:expense:update-category' });
  const data = resp.data;
  if (data.code !== 0) throw new Error(`Update expense ${expenseId}: Zoho code ${data.code}: ${data.message}`);
  return true;
}

async function main() {
  console.log(`=== PRP Stage 7c: Category Sync (${entity}) ===`);
  console.log(`Mode: ${dryRun ? 'DRY RUN' : 'LIVE'}`);

  // 1. Auth
  console.log('\n1. Getting credentials...');
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();

  // 2. Read TAS
  console.log(`\n2. Reading TAS: ${TAS_PATH}`);
  if (!fs.existsSync(TAS_PATH)) throw new Error(`TAS not found: ${TAS_PATH}`);
  const tas = parseTasCsv(fs.readFileSync(TAS_PATH, 'utf8'));
  console.log(`   ${tas.length} rows`);

  const matched = tas.filter(r => r.zoho_expense_id);
  console.log(`   ${matched.length} rows with zoho_expense_id`);

  // 3. For each matched row, fetch current category and compare
  console.log('\n3. Checking categories...');
  let ok = 0, needsUpdate = 0, skipped = 0, errors = 0;

  for (const row of matched) {
    const expenseId = row.zoho_expense_id;
    const tasCat = row.category;
    const expectedAccountId = CATEGORY_MAP[tasCat];

    if (!expectedAccountId) {
      console.warn(`   [SKIP] No mapping for category "${tasCat}" (expense ${expenseId})`);
      skipped++;
      continue;
    }

    try {
      const expense = await fetchExpense(auth, expenseId);
      const currentAccountId = expense.account_id;

      if (currentAccountId === expectedAccountId) {
        ok++;
        continue;
      }

      console.log(`   [CHANGE] expense ${expenseId}`);
      console.log(`     TAS category: ${tasCat} -> account ${expectedAccountId}`);
      console.log(`     Zoho current: "${expense.account_name}" (${currentAccountId})`);

      if (!dryRun) {
        await updateExpenseCategory(auth, expenseId, expectedAccountId);
        console.log(`     [UPDATED]`);
        needsUpdate++;
      } else {
        needsUpdate++;
      }
    } catch (err) {
      console.error(`   [ERROR] expense ${expenseId}: ${err.message}`);
      errors++;
    }

    await sleep(600);
  }

  console.log(`\n=== Summary ===`);
  console.log(`   Already correct: ${ok}`);
  console.log(`   Needs update: ${needsUpdate}`);
  console.log(`   Skipped (no mapping): ${skipped}`);
  console.log(`   Errors: ${errors}`);

  if (dryRun && needsUpdate > 0) {
    console.log(`\nRun without --dry-run to apply ${needsUpdate} changes.`);
  }
}

main().catch(err => { console.error(`FATAL: ${err.message}`); process.exit(1); });
