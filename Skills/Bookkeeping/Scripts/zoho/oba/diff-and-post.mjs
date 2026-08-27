#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { ZohoAuth } = require('../zoho-auth.js');
const { resolveSync } = require('../resolve-zoho-creds.mjs');

function formatAmount(n) {
  return (n < 0 ? '-$' : '$') + Math.abs(n).toFixed(2);
}

function generateDiffReport(mappedState, currentState, dryRun) {
  const lines = [];
  const bankAccts = [];
  const nonBankAccts = [];
  const obaBalancingEntries = [];

  const bankMap = {};
  for (const ba of currentState.bank_accounts) {
    bankMap[ba.id] = ba;
  }

  for (const acct of mappedState.resolved_accounts) {
    if (acct.type === 'bank' || acct.type === 'credit_card') {
      const current = bankMap[acct.zoho_id];
      const currentVal = current ? current.opening_balance : null;
      let status = 'NEEDS_SET';
      if (currentVal === parseFloat(acct.amount.toFixed(2))) {
        status = 'MATCHED';
      } else if (currentVal !== null) {
        status = 'MISMATCH';
      }
      bankAccts.push({ ...acct, current_value: currentVal, status });
    } else {
      nonBankAccts.push(acct);
    }
  }

  let totalDebits = 0;
  let totalCredits = 0;

  for (const acct of bankAccts) {
    if (parseFloat(acct.amount) > 0) totalDebits += parseFloat(acct.amount);
    else totalCredits += Math.abs(parseFloat(acct.amount));
  }
  for (const acct of nonBankAccts) {
    if (parseFloat(acct.amount) > 0) totalDebits += parseFloat(acct.amount);
    else totalCredits += Math.abs(parseFloat(acct.amount));
  }

  const obaOffset = parseFloat((totalCredits - totalDebits).toFixed(2));
  const obaSign = obaOffset >= 0 ? 'credit' : 'debit';

  lines.push('=== OBA Diff Report ===');
  lines.push(`Organization: ${currentState.organization_id}`);
  lines.push(`Mode: ${dryRun ? 'DRY-RUN' : 'APPLY'}`);
  lines.push(`Fetched at: ${currentState.fetched_at}`);
  lines.push('');

  if (bankAccts.length > 0) {
    lines.push('Bank Accounts:');
    for (const ba of bankAccts) {
      const currentStr = ba.current_value !== null ? formatAmount(ba.current_value) : 'null';
      const expectedStr = formatAmount(ba.amount);
      lines.push(`  [${ba.zoho_id}] ${ba.zoho_name}: ${currentStr} → ${expectedStr}  (${ba.status})`);
    }
    lines.push('');
  }

  if (nonBankAccts.length > 0) {
    lines.push('Non-Bank Accounts (require journal entry):');
    for (const nb of nonBankAccts) {
      lines.push(`  [${nb.zoho_id || '?'}] ${nb.zoho_name || nb.name}: ${formatAmount(nb.amount)}  (${nb.sign})`);
    }
    lines.push('');
  }

  lines.push('Summary:');
  lines.push(`  Total accounts: ${bankAccts.length + nonBankAccts.length}`);
  lines.push(`  Bank matched: ${bankAccts.filter(a => a.status === 'MATCHED').length}`);
  lines.push(`  Bank needs set: ${bankAccts.filter(a => a.status === 'NEEDS_SET').length}`);
  lines.push(`  Bank mismatch: ${bankAccts.filter(a => a.status === 'MISMATCH').length}`);
  lines.push(`  Non-bank accounts: ${nonBankAccts.length}`);
  lines.push(`  Unmatched accounts: ${mappedState.unmatched_accounts.length}`);
  lines.push('');
  lines.push('Journal Entry Summary:');
  lines.push(`  Total debits: ${formatAmount(totalDebits)}`);
  lines.push(`  Total credits: ${formatAmount(totalCredits)}`);
  lines.push(`  OBA offset (${obaSign}): ${formatAmount(Math.abs(obaOffset))}`);

  if (mappedState.oba_account) {
    lines.push(`  OBA account: ${mappedState.oba_account.zoho_name} (${mappedState.oba_account.zoho_id})`);
  }

  return {
    report: lines.join('\n'),
    bank_accounts: bankAccts,
    non_bank_accounts: nonBankAccts,
    oba_offset: obaOffset,
    oba_sign: obaSign,
    needs_apply: bankAccts.some(a => a.status !== 'MATCHED') || nonBankAccts.length > 0,
  };
}

function generateManualJournalFile(diffResult, mappedState, orgId) {
  let journalLines = [];
  const date = '2025-04-01';

  journalLines.push('# OBA Journal Entries — Post Manually in Zoho UI');
  journalLines.push('');
  journalLines.push(`Generated: ${new Date().toISOString()}`);
  journalLines.push(`Organization: ${orgId}`);
  journalLines.push('');
  journalLines.push('## Instructions');
  journalLines.push('1. Go to Zoho Books → Accounting → Journal Entries → Create');
  journalLines.push(`2. Set date to: ${date}`);
  journalLines.push('3. Notes: "FY2026 opening balance entry — from FY2025 S100"');
  journalLines.push('4. Add the following line items:');
  journalLines.push('');

  journalLines.push('| Account | Debit/Credit | Amount |');
  journalLines.push('|---------|-------------|--------|');

  const allEntries = [];

  for (const ba of diffResult.bank_accounts) {
    if (ba.status === 'MATCHED') continue;
    const amount = Math.abs(ba.amount);
    allEntries.push({
      account: ba.zoho_name,
      account_id: ba.zoho_id,
      type: ba.amount >= 0 ? 'debit' : 'credit',
      amount,
      note: ba.type === 'credit_card' ? 'Credit card' : 'Bank'
    });
  }

  for (const nb of diffResult.non_bank_accounts) {
    const amount = Math.abs(nb.amount);
    allEntries.push({
      account: nb.zoho_name || nb.name,
      account_id: nb.zoho_id || '(unknown)',
      type: nb.sign || (nb.amount >= 0 ? 'debit' : 'credit'),
      amount,
      note: ''
    });
  }

  allEntries.push({
    account: 'Opening Balance Adjustments',
    account_id: mappedState.oba_account ? mappedState.oba_account.zoho_id : '(auto-created)',
    type: diffResult.oba_sign,
    amount: Math.abs(diffResult.oba_offset),
    note: 'Balancing figure'
  });

  for (const entry of allEntries) {
    journalLines.push(`| ${entry.account} (${entry.account_id}) | ${entry.type} | ${formatAmount(entry.amount)} |`);
  }

  journalLines.push('');
  journalLines.push(`Total debits = Total credits = ${formatAmount([...allEntries].reduce((s, e) => s + e.amount, 0))}`);
  journalLines.push('');
  journalLines.push('## Alternative: POST /journals via API');
  journalLines.push('');
  journalLines.push('```json');
  journalLines.push('{');
  journalLines.push('  "journal": {');
  journalLines.push(`    "journal_date": "${date}",`);
  journalLines.push('    "journal_notes": "FY2026 opening balance entry — from FY2025 S100",');
  journalLines.push('    "line_items": [');
  for (const entry of allEntries) {
    journalLines.push(`      { "account_id": "${entry.account_id}", "debit_or_credit": "${entry.type}", "amount": ${entry.amount.toFixed(2)} },`);
  }
  journalLines.push('    ]');
  journalLines.push('  }');
  journalLines.push('}');
  journalLines.push('```');
  journalLines.push('');
  journalLines.push('POST to: https://www.zohoapis.com/books/v3/journals?organization_id=' + orgId);

  return journalLines.join('\n');
}

export async function diffAndPost({ mappedState, currentState, dryRun = true, orgId, token }) {
  const diffResult = generateDiffReport(mappedState, currentState, dryRun);

  if (dryRun) {
    console.log(diffResult.report);
    return { dry_run: true, changes_needed: diffResult.needs_apply, diff: diffResult };
  }

  const creds = resolveSync();
  const auth = ZohoAuth.getInstance({
    clientId: creds.ZOHO_BOOKS_ID,
    clientSecret: creds.ZOHO_BOOKS_SECRET,
    refreshToken: creds.ZOHO_BOOKS_REFRESH,
  });
  const accessToken = token || await auth.getToken();
  const headers = {
    Authorization: `Zoho-oauthtoken ${accessToken}`,
    'Content-Type': 'application/json',
  };
  const baseUrl = auth.baseUrl || 'https://www.zohoapis.com/books/v3';

  const posted = [];
  const skipped = [];
  const errors = [];

  for (const ba of diffResult.bank_accounts) {
    if (ba.status === 'MATCHED') {
      skipped.push({ account: ba.zoho_name, reason: 'Already matched' });
      continue;
    }
    const body = JSON.stringify({
      account_id: ba.zoho_id,
      opening_balance: parseFloat(ba.amount.toFixed(2)),
      opening_balance_date: '2025-04-01',
    });
    const url = `${baseUrl}/bankaccounts/${ba.zoho_id}?organization_id=${orgId}`;
    try {
      const resp = await fetch(url, { method: 'PUT', headers, body });
      const data = await resp.json();
      if (resp.ok) {
        posted.push({ account: ba.zoho_name, zoho_id: ba.zoho_id, amount: ba.amount });
        console.log(`  POSTED: ${ba.zoho_name} → ${formatAmount(ba.amount)}`);
      } else {
        const errMsg = `${resp.status}: ${JSON.stringify(data).substring(0, 200)}`;
        errors.push({ account: ba.zoho_name, error: errMsg });
        console.error(`  ERROR: ${ba.zoho_name} — ${errMsg}`);
      }
    } catch (e) {
      errors.push({ account: ba.zoho_name, error: e.message });
      console.error(`  ERROR: ${ba.zoho_name} — ${e.message}`);
    }
  }

  let journalFilePath = null;
  if (diffResult.non_bank_accounts.length > 0 || errors.length > 0) {
    const journalContent = generateManualJournalFile(diffResult, mappedState, orgId);
    journalFilePath = path.resolve('oba-journal-entries-POST-MANUALLY.md');
    fs.writeFileSync(journalFilePath, journalContent, 'utf8');
    console.log(`\nManual journal entries written to: ${journalFilePath}`);
  }

  const summary = {
    posted_accounts: posted,
    skipped_accounts: skipped,
    errors,
    journal_entries_file: journalFilePath,
    all_bank_accounts_posted: posted.length > 0 && errors.length === 0,
  };

  console.log('\n=== Apply Summary ===');
  console.log(`  Posted: ${posted.length} bank account(s)`);
  console.log(`  Skipped: ${skipped.length} (already matched)`);
  console.log(`  Errors: ${errors.length}`);
  if (journalFilePath) console.log(`  Journal file: ${journalFilePath}`);

  return { dry_run: false, summary };
}

async function main() {
  const args = process.argv.slice(2);
  let orgId = null;
  let expectedPath = null;
  let currentPath = null;
  let apply = false;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--org') orgId = args[++i];
    if (args[i] === '--expected') expectedPath = args[++i];
    if (args[i] === '--current') currentPath = args[++i];
    if (args[i] === '--apply') apply = true;
  }

  if (!orgId || !expectedPath || !currentPath) {
    console.error('Usage: node diff-and-post.mjs --org <orgId> --expected <mapped.json> --current <current.json> [--apply]');
    process.exit(1);
  }

  const mappedState = JSON.parse(fs.readFileSync(expectedPath, 'utf8'));
  const currentState = JSON.parse(fs.readFileSync(currentPath, 'utf8'));

  await diffAndPost({ mappedState, currentState, dryRun: !apply, orgId });
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { console.error(e.message); process.exit(1); });
}
