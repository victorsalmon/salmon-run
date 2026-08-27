#!/usr/bin/env node
import fs from 'fs';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { ZohoAuth } = require('../zoho-auth.js');
const { resolveSync } = require('../resolve-zoho-creds.mjs');

export async function fetchCurrentOba(orgId, token) {
  const creds = resolveSync();
  const auth = ZohoAuth.getInstance({
    clientId: creds.ZOHO_BOOKS_ID,
    clientSecret: creds.ZOHO_BOOKS_SECRET,
    refreshToken: creds.ZOHO_BOOKS_REFRESH,
  });
  const accessToken = token || await auth.getToken();
  const headers = { Authorization: `Zoho-oauthtoken ${accessToken}` };
  const baseUrl = auth.baseUrl || 'https://www.zohoapis.com/books/v3';

  async function fetchJson(url) {
    const resp = await fetch(url, { headers });
    if (!resp.ok) {
      throw new Error(`GET ${url.substring(0, 100)} returned ${resp.status}: ${await resp.text()}`);
    }
    return resp.json();
  }

  const bankAccountsUrl = `${baseUrl}/bankaccounts?organization_id=${orgId}&per_page=200`;
  const bankData = await fetchJson(bankAccountsUrl);
  const bankAccounts = (bankData.bankaccounts || []).map(ba => ({
    id: ba.account_id,
    name: ba.account_name,
    opening_balance: ba.opening_balance != null ? ba.opening_balance : null,
    balance: ba.balance,
    bank_balance: ba.bank_balance,
    currency_id: ba.currency_id,
  }));

  const coaUrl = `${baseUrl}/settings/accounts?organization_id=${orgId}&per_page=200`;
  const coaData = await fetchJson(coaUrl);

  let obaJournalEntries = [];
  const obaAccount = (coaData.accounts || []).find(a =>
    a.account_type === 'equity' && /opening.*balance/i.test(a.account_name)
  );
  if (obaAccount) {
    const journalUrl = `${baseUrl}/journals?organization_id=${orgId}&account_id=${obaAccount.account_id}&per_page=200`;
    const journalData = await fetchJson(journalUrl);
    obaJournalEntries = journalData.journals || [];
  }

  return {
    organization_id: orgId,
    fetched_at: new Date().toISOString(),
    bank_accounts: bankAccounts,
    chart_of_accounts: coaData.accounts || [],
    oba_account: obaAccount ? {
      id: obaAccount.account_id,
      name: obaAccount.account_name,
    } : null,
    oba_journal_entries: obaJournalEntries,
  };
}

async function main() {
  const args = process.argv.slice(2);
  let orgId = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--org') orgId = args[++i];
  }
  if (!orgId) {
    console.error('Usage: node fetch-current-oba.mjs --org <orgId>');
    process.exit(1);
  }
  const result = await fetchCurrentOba(orgId);
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { console.error(e.message); process.exit(1); });
}
