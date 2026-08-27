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
const { parseArgs, loadEntityConfig, sleep } = require('./lib/zoho-common.js');
const { fetchWithAudit } = require('./lib/audit-logger.mjs');

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
    
    // Get transactions
    let page = 1, allTxns = [];
    while (true) {
      const txnUrl = `https://www.zohoapis.com/books/v3/banktransactions?organization_id=${ORG_ID}&bank_account_id=${acctId}&page=${page}&per_page=200`;
      const txnResp = await fetchWithAudit(txnUrl, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:banktransactions:list' });
      if (!txnResp.ok) throw new Error(`Bank txns: HTTP ${txnResp.status}`);
      const txnData = txnResp.data;
      if (txnData.code !== 0) throw new Error(`Bank txns: ${txnData.message}`);
      allTxns = allTxns.concat(txnData.banktransactions || []);
      if (!txnData.page_context?.has_more_page) break;
      page++;
      await sleep(300);
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
