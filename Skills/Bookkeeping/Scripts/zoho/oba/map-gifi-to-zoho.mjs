#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { ZohoAuth } = require('../zoho-auth.js');
const { resolveSync, getOrgId } = require('../resolve-zoho-creds.mjs');

const GIFI_TO_ZOHO = {
  1001: { zoho_name: '[1001] RBC Intersite', zoho_id: '93310000000100019', type: 'bank', sign: 'debit' },
  '1001_mc': { zoho_name: '[1001] Intersite RBC Business Cash Back Mastercard', zoho_id: '93310000000100013', type: 'credit_card', sign: 'credit' },
  1774: { zoho_name: null, zoho_id: null, type: 'asset', sign: 'debit', lookup: true, expected_names: ['Computer Equipment', 'Office Equipment', 'Computers'] },
  1775: { zoho_name: null, zoho_id: null, type: 'contra_asset', sign: 'credit', lookup: true, expected_names: ['Accumulated Depreciation', 'Accum. Depreciation', 'Accum Depreciation'] },
  1740: { zoho_name: null, zoho_id: null, type: 'asset', sign: 'debit', lookup: true, expected_names: ['Furniture and Fixtures', 'Furniture & Fixtures', 'Office Furniture'] },
  1741: { zoho_name: null, zoho_id: null, type: 'contra_asset', sign: 'credit', lookup: true, expected_names: ['Accumulated Depreciation', 'Accum. Depreciation', 'Accum Depreciation'] },
  2620: { zoho_name: null, zoho_id: null, type: 'liability', sign: 'credit', lookup: true, expected_names: ['Accounts Payable', 'Trade Payables', 'AP'] },
  2680: { zoho_name: 'Corporate Income Tax Payable', zoho_id: '93310000000138058', type: 'liability', sign: 'credit' },
  3500: { zoho_name: 'Share Capital', zoho_id: '93310000000125064', type: 'equity', sign: 'credit' },
  3849: { zoho_name: null, zoho_id: null, type: 'equity', sign: 'credit', lookup: true, expected_names: ['Retained Earnings', 'Retained Earnings (Deficit)'] },
};

function normalize(str) {
  return str.toLowerCase().replace(/[^a-z0-9]/g, '');
}

function fuzzyMatch(accountName, expectedNames) {
  const norm = normalize(accountName);
  for (const expected of expectedNames) {
    const normExpected = normalize(expected);
    if (norm === normExpected) return true;
    if (norm.includes(normExpected) || normExpected.includes(norm)) return true;
  }
  return false;
}

function findObaAccount(accounts) {
  return accounts.find(a =>
    a.account_type === 'equity' &&
    /opening.*balance/i.test(a.account_name)
  );
}

export async function mapGifiToZoho(extracted, orgId, token) {
  const creds = resolveSync();
  const auth = ZohoAuth.getInstance({
    clientId: creds.ZOHO_BOOKS_ID,
    clientSecret: creds.ZOHO_BOOKS_SECRET,
    refreshToken: creds.ZOHO_BOOKS_REFRESH,
  });
  const accessToken = token || await auth.getToken();

  const coaUrl = `https://www.zohoapis.com/books/v3/settings/accounts?organization_id=${orgId}`;
  const coaResp = await fetch(coaUrl, {
    headers: { Authorization: `Zoho-oauthtoken ${accessToken}` }
  });
  const coaData = await coaResp.json();
  const allAccounts = coaData.accounts || [];

  const obaAccount = findObaAccount(allAccounts);
  const resolvedEntries = [];
  const unmatchedEntries = [];

  for (const acct of extracted.accounts) {
    let gifiKey = acct.gifi;
    const bankAcctKey = `${acct.gifi}_mc`;
    let mapping = GIFI_TO_ZOHO[gifiKey];

    if (!mapping && GIFI_TO_ZOHO[bankAcctKey]) {
      mapping = GIFI_TO_ZOHO[bankAcctKey];
    }

    if (!mapping) {
      unmatchedEntries.push({ gifi: acct.gifi, name: acct.name, amount: acct.amount, reason: 'No GIFI mapping defined' });
      continue;
    }

    if (mapping.lookup && mapping.expected_names) {
      const candidates = allAccounts.filter(a => a.is_active !== false);
      let match = null;
      for (const candidate of candidates) {
        if (fuzzyMatch(candidate.account_name, mapping.expected_names)) {
          if (!match || candidate.account_name.length < match.account_name.length) {
            match = candidate;
          }
        }
      }
      if (match) {
        mapping = { ...mapping, zoho_name: match.account_name, zoho_id: match.account_id, lookup: false };
      } else {
        unmatchedEntries.push({
          gifi: acct.gifi,
          name: acct.name,
          amount: acct.amount,
          reason: `Could not find account in Zoho CoA. Expected names: ${mapping.expected_names.join(', ')}`
        });
        continue;
      }
    }

    resolvedEntries.push({
      gifi: acct.gifi,
      name: acct.name,
      amount: acct.amount,
      zoho_name: mapping.zoho_name,
      zoho_id: mapping.zoho_id,
      type: mapping.type,
      sign: mapping.sign,
    });
  }

  return {
    organization_id: orgId,
    resolved_accounts: resolvedEntries,
    unmatched_accounts: unmatchedEntries,
    oba_account: obaAccount ? { zoho_id: obaAccount.account_id, zoho_name: obaAccount.account_name } : null,
    all_resolved: unmatchedEntries.length === 0,
  };
}

async function main() {
  const args = process.argv.slice(2);
  let orgId = null;
  let extractedPath = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--org') orgId = args[++i];
    if (args[i] === '--extracted') extractedPath = args[++i];
  }
  if (!orgId || !extractedPath) {
    console.error('Usage: node map-gifi-to-zoho.mjs --org <orgId> --extracted <extracted.json>');
    process.exit(1);
  }
  const extracted = JSON.parse(fs.readFileSync(extractedPath, 'utf8'));
  const result = await mapGifiToZoho(extracted, orgId);
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { console.error(e.message); process.exit(1); });
}
