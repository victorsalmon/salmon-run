#!/usr/bin/env node
// Fetch Zoho bank account balances and recent transactions
// Mark Plaid-synced transactions for reconciliation verification.
//
// Used by: Skills/Bookkeeping/books/reconciliation/prp-stage7-cloud-alignment.md § Sub-stage 7d helper
//
// Usage:
//   node check-zoho-balances.mjs                              # room-rentals
//   node check-zoho-balances.mjs --entity intersite-consulting

import { ZohoAuth } from './zoho-auth.js';
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
const require = createRequire(import.meta.url);
const { parseArgs, loadEntityConfig, sleep } = require('../shared/lib/zoho-common.js');
const { fetchWithAudit } = require('../shared/lib/audit-logger.mjs');

const args = parseArgs();
const entity = args.entity || 'room-rentals';
const { config, ec } = loadEntityConfig(entity);
const ORG_ID = ec.org_id;

async function main() {
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();

  console.log(`=== Zoho Balance & Transaction Check (${entity}) ===`);

  // 1. Fetch bank accounts with balances
  console.log('\n1. Bank Accounts:');
  let url = `https://www.zohoapis.com/books/v3/bankaccounts?organization_id=${ORG_ID}`;
  let resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:bankaccounts:list' });
  if (!resp.ok) throw new Error(`Bank accounts: HTTP ${resp.status}`);
  let data = resp.data;
  if (data.code !== 0) throw new Error(`Bank accounts: ${data.message}`);

  const accounts = {};
  for (const acct of data.bankaccounts || []) {
    const isPlaid = acct.is_plaid_connected;
    const label = `${acct.account_name} (${acct.account_id})`;
    accounts[acct.account_id] = { name: acct.account_name, balance: parseFloat(acct.current_balance || 0), isPlaid };
    console.log(`  ${label}: balance=$${acct.current_balance} plaid=${isPlaid}`);
  }

  // 2. Fetch all bank transactions for period checking
  console.log('\n2. Fetching bank transactions...');
  const TAS_PATH = path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity, 'TAS-2026.csv');
  const tasExists = fs.existsSync(TAS_PATH);

  // Fetch transactions per account
  for (const [acctId, acctInfo] of Object.entries(accounts)) {
    if (!acctInfo.isPlaid) { console.log(`  Skipping ${acctInfo.name} (not Plaid-linked)`); continue; }
    console.log(`\n  --- ${acctInfo.name} (${acctId}) ---`);
    
    // Get transactions — fetch both categorized and uncategorized
    async function fetchByStatus(status) {
      let page = 1, result = [];
      while (true) {
        let url = `https://www.zohoapis.com/books/v3/banktransactions?organization_id=${ORG_ID}&bank_account_id=${acctId}&page=${page}&per_page=200`;
        if (status) url += `&status=${status}`;
        const resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:banktransactions:list' });
        if (!resp.ok) throw new Error(`Bank txns: HTTP ${resp.status}`);
        const data = resp.data;
        if (data.code !== 0) throw new Error(`Bank txns: ${data.message}`);
        result = result.concat(data.banktransactions || []);
        if (!data.page_context?.has_more_page) break;
        page++;
        await sleep(300);
      }
      return result;
    }
    const [categorized, uncategorized] = await Promise.all([
      fetchByStatus(''),
      fetchByStatus('uncategorized'),
    ]);
    const seen = new Set();
    const allTxns = [];
    for (const t of [...categorized, ...uncategorized]) {
      if (!seen.has(t.transaction_id)) { seen.add(t.transaction_id); allTxns.push(t); }
    }

    console.log(`     Total transactions: ${allTxns.length}`);
    
    // Mark which are Plaid-synced
    const plaidTxns = allTxns.filter(t => t.is_imported || t.payment_type === 'imported');
    const manualTxns = allTxns.filter(t => !t.is_imported && t.payment_type !== 'imported');
    console.log(`     Plaid-synced: ${plaidTxns.length}`);
    console.log(`     Manual: ${manualTxns.length}`);

    // Sort by date
    allTxns.sort((a, b) => a.transaction_date.localeCompare(b.transaction_date));

    // Find date range
    if (allTxns.length > 0) {
      const firstDate = allTxns[0].transaction_date;
      const lastDate = allTxns[allTxns.length - 1].transaction_date;
      const balance = acctInfo.balance;
      console.log(`     Date range: ${firstDate} to ${lastDate}`);
      console.log(`     Current balance: $${balance.toFixed(2)}`);

      // Compute sum of all debits and credits
      let totalDebits = 0, totalCredits = 0;
      for (const t of allTxns) {
        const amt = parseFloat(t.amount || t.debit_or_credit_amount || 0);
        if (t.debit_or_credit === 'debit' || t.transaction_type === 'withdrawal') totalDebits += amt;
        else totalCredits += amt;
      }
      console.log(`     Total debits: $${totalDebits.toFixed(2)}, credits: $${totalCredits.toFixed(2)}`);
      
      // Compute implied opening balance: current_balance - net_flow
      const netFlow = totalCredits - totalDebits;
      const openingBalance = balance - netFlow;
      console.log(`     Net flow: $${netFlow.toFixed(2)}`);
      console.log(`     Implied opening balance (work backwards): $${openingBalance.toFixed(2)}`);
    }
  }

  // 3. If TAS exists, compare periods
  if (tasExists) {
    console.log('\n3. TAS comparison: see Invoke-ReconciliationCheck.ps1 -LocalBooks');
  }

  console.log(`\n=== Done ===`);
}

main().catch(err => { console.error(`FATAL: ${err.message}`); process.exit(1); });
