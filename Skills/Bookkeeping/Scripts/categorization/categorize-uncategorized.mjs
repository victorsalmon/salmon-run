#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import os from 'os';
import { resolveSync } from '../zoho/resolve-zoho-creds.mjs';

const BOOKS_DIR = path.resolve(process.env.USERPROFILE || os.homedir(), 'intersite-docs', 'Taxes and Bookkeeping');

const ORG_ID = '925048093';

const CATEGORY_ACCT_IDS = {
  '[8962] Motor vehicles repairs and maintenance': '93310000000000424',
  '[9150] Tech repair, support, subscriptions, peripherals': '93310000000582161',
  'Office & General Expenses':    '93310000000000400',
  'Repairs and Maintenance':      '93310000000000457',
  'Professional Fees':            '93310000000135091',
  'Advertising And Marketing':    '93310000000000403',
  'Bank Fees and Charges':        '93310000000000409',
  'Credit Card Charges':          '93310000000000412',
  'Other Expenses':               '93310000000000460',
  'Lease Expense':                '93310000000217488',
  'Telephone':                    '93310000000000421',
  'Shareholder Loan':             '93310000000146154',
  'Income Tax Expense':           '93310000000297002',
  'Consulting Revenue':           '93310000000149102',
  'Credit Card Payments':         '93310000000300002',
  'Exclude':                      '93310000000161002',
  'Intersite':                    '93310000000100013',
};

const VENDOR_RULES = [
  { rx: /ROOMIES/i,                                                             cat: 'Advertising And Marketing' },
  { rx: /FREEDOM\s*MOBILE|FONGO|GOOGLE\s+\*FONGO|GOOGLE\s+.*FONGO/i,           cat: 'Telephone' },
  { rx: /PETRO|SHELL|CHEVRON|CHV\d+|GAS\b|CO-OP|CANCO|SUPER\s*SAVE|ESSO|MOBIL(?!E)/i, cat: '[8962] Motor vehicles repairs and maintenance' },
  { rx: /KAL[-?\s]*TIRE|LORDCO|IMPARK|PARKING/i,                               cat: '[8962] Motor vehicles repairs and maintenance' },
  { rx: /ICBC/i,                                                               cat: '[8962] Motor vehicles repairs and maintenance' },
  { rx: /SCIENER|ZOHO|INTERSERVER|KILO\s*CODE|ANOMALY|WAVE\s*PRO/i,            cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /OPENAI|OPENROUTER|STRIPE[.-]?Z|PIXELLA|ROOMIES/i,                     cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /LIGHTSPEED|FREEDOM\s*MOBILE|TELEPHONE/i,                              cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /MYCLAW|SQUARESPACE|NAMECHEAP|CREATIVE\s*FABRICA|P\.SKOOL/i,            cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /BITWARDEN|TIDYCAL|BREEZEDOC|APP.?SUMO|WP.?FORMS/i,                    cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /BOLDSIGN|UDEMY/i,                                                      cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /SQSP\s*\*|MOZSEO|NAME.?CHEAP/i,                                       cat: '[9150] Tech repair, support, subscriptions, peripherals' },
  { rx: /REINVESTWEALTH/i,                                                      cat: 'Professional Fees' },
  { rx: /LEGALSHIELD/i,                                                         cat: 'Professional Fees' },
  { rx: /CIVIL\s*RESOLUTION|BC\s*REGISTR|GOVERNMENT|REGISTRATION/i,             cat: 'Professional Fees' },
  { rx: /THE\s*BUGMAN|VERNON\s*LOCK|OZERTY|SALES\s*DRAFT/i,                     cat: 'Repairs and Maintenance' },
  { rx: /HOME\s*DEPOT|DULUX|VISIONS\s*ELECTRONICS|TEMU/i,                       cat: 'Repairs and Maintenance' },
  { rx: /PURCHASE\s*INTEREST/i,                                                 cat: 'Bank Fees and Charges' },
  { rx: /STAPLES|BEST\s*BUY|DOLLARAMA/i,                                       cat: 'Office & General Expenses' },
  { rx: /Amazon\s*Web\s*Services|AWS\b/i,                                       cat: 'Software & IT Expenses' },
  { rx: /AMZN\s*Mktp\s*CA\*?G99W19UW3/i,                                       cat: 'Repairs and Maintenance' },
  { rx: /AMAZON|AMZN/i,                                                         cat: 'Office & General Expenses' },
  { rx: /UPSCALE\s*HAVENS/i,                                                    cat: 'Consulting Revenue' },
  { rx: /PAYPAL/i,                                                              cat: 'Other Expenses' },
  { rx: /SGT\*PIXELLA/i,                                                       cat: 'Software & IT Expenses' },
  { rx: /GOOGLE\s+\*FONGO|GOOGLE\s+.*FONGO/i,                                 cat: 'Software & IT Expenses' },
  { rx: /CLEAN-IT\s*ALL|CLEAN-IT/i,                                             cat: 'Repairs and Maintenance' },
  { rx: /COFOODBANK|FOOD\s*BANK/i,                                              cat: 'Advertising And Marketing' },
  { rx: /MONTHLY\s*FEE|PAY-FILE|ACCOUNT\s*FEE/i,                                cat: 'Bank Fees and Charges' },
  { rx: /FACEBOOK|META|GOOGLE\s*ADS/i,                                          cat: 'Advertising And Marketing' },
  { rx: /NETFLIX|SPOTIFY/i,                                                     cat: 'Office & General Expenses' },
  { rx: /PAD\s+CCRA|CCRA|CANADA\s+REVENUE/i,                                     cat: 'Income Tax Expense' },
  { rx: /DOMAIN\s+S\./i,                                                        cat: 'Software & IT Expenses' },
  { rx: /PAYMENT\s*[-–]\s*THANK|PAIEMENT/i,                                     cat: 'Credit Card Payments' },
];

function categorizeFromVendor(payee, description) {
  const text = ((payee || '') + ' ' + (description || '')).trim();
  if (!text) return null;
  for (const rule of VENDOR_RULES) {
    if (rule.rx.test(text)) return rule.cat;
  }
  return null;
}

function parseCsv(filePath) {
  if (!fs.existsSync(filePath)) return null;
  const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  const lines = raw.split('\n').map(l => l.trim()).filter(l => l);
  if (lines.length < 2) return [];
  const headerLine = lines.find(l => !l.startsWith('#'));
  if (!headerLine) return [];
  const headers = headerLine.split(',').map(h => h.replace(/^"|"$/g, '').trim());
  const dataLines = lines.filter(l => !l.startsWith('#') && l !== headerLine);
  return dataLines.map(l => {
    const vals = []; let cur = '', q = false, i = 0;
    for (const ch of l) {
      i++;
      if (ch === '"') { q = !q; continue; }
      if (ch === ',' && !q) { vals.push(cur.trim()); cur = ''; continue; }
      cur += ch;
    }
    vals.push(cur.trim());
    const obj = {}; headers.forEach((h, idx) => obj[h] = vals[idx] || '');
    return obj;
  });
}

async function main() {
  const args = process.argv.slice(2);
  const apply = args.includes('--apply');

  const mcDir = path.join(BOOKS_DIR, 'intersite-consulting', '2026 Filing', '2026 Bank Statements', 'MC 6241 (6258)');
  const rbcDir = path.join(BOOKS_DIR, 'intersite-consulting', '2026 Filing', '2026 Bank Statements', 'RBC-INTERSITE');

  const mcCsv = path.join(mcDir, '2026.06.15-Present - MC 6258 (MasterCard 6241) - Zoho.csv');
  const rbcCsv = path.join(rbcDir, '2026.06.15-Present - RBC Intersite (Chequing 6632) - Zoho.csv');

  console.log('=== Intersite Consulting — Categorize Uncategorized ===');
  if (apply) console.log('  MODE: APPLY — will update Zoho');
  else console.log('  MODE: Dry-run — no changes made');
  console.log();

  const toCategorize = [];

  for (const [name, csvPath, acctSlug] of [
    ['MC 6258', mcCsv, 'MC-6258'],
    ['RBC Intersite', rbcCsv, 'RBC-INTERSITE'],
  ]) {
    const rows = parseCsv(csvPath);
    if (!rows) { console.log(`  [SKIP] ${name}: CSV not found at ${csvPath}`); continue; }
    console.log(`${name}: ${rows.length} transactions in Zoho CSV`);

    for (const row of rows) {
      const ttype = (row.transaction_type || '').trim();
      if (ttype !== 'uncategorized') continue;

      const zId = (row.zoho_transaction_id || '').trim();
      if (!zId) continue;

      const payee = (row.payee || '').trim();
      const description = (row.description || '').trim();
      const dc = (row.debit_or_credit || '').trim().toLowerCase();
      const amount = parseFloat(row.amount || 0);

      const suggestedCat = categorizeFromVendor(payee, description);
      if (!suggestedCat) {
        toCategorize.push({
          zoho_transaction_id: zId, payee, description, dc, amount,
          account: name, account_slug: acctSlug,
          suggestedCategory: null, note: 'UNMATCHED — no vendor rule',
        });
        continue;
      }

      toCategorize.push({
        zoho_transaction_id: zId, payee, description, dc, amount,
        account: name, account_slug: acctSlug,
        suggestedCategory: suggestedCat, note: '',
      });
    }
  }

  console.log(`\n=== ${toCategorize.length} uncategorized transactions found ===`);

  const matched = toCategorize.filter(t => t.suggestedCategory);
  const unmatched = toCategorize.filter(t => !t.suggestedCategory);

  if (matched.length > 0) {
    console.log(`\n=== Categorizable (${matched.length}) ===`);
    for (const t of matched) {
      const dir = t.dc === 'debit' ? '→' : '←';
      console.log(`  ${t.account} | ${t.payee.padEnd(25)} | $${t.amount.toFixed(2).padStart(8)} ${dir} ${t.suggestedCategory}`);
    }
  }

  if (unmatched.length > 0) {
    console.log(`\n=== UNMATCHED (${unmatched.length}) — needs manual review ===`);
    for (const t of unmatched) {
      console.log(`  ${t.account} | ${t.payee.padEnd(25)} | $${t.amount.toFixed(2).padStart(8)} | ${t.description}`);
    }
  }

  console.log();

  if (!apply || matched.length === 0) {
    console.log(matched.length === 0 ? 'Nothing to apply.' : 'Dry-run complete. Use --apply to update Zoho.');
    return;
  }

  // ── Apply: categorize via Zoho API ──────────────────────────────────
  console.log('=== Applying categorizations to Zoho ===');

  let creds;
  try {
    if (process.env.ZOHO_BOOKS_ID && process.env.ZOHO_BOOKS_SECRET && process.env.ZOHO_BOOKS_REFRESH) {
      creds = {
        clientId: process.env.ZOHO_BOOKS_ID,
        clientSecret: process.env.ZOHO_BOOKS_SECRET,
        refreshToken: process.env.ZOHO_BOOKS_REFRESH,
        orgId: ORG_ID,
      };
    } else {
      const resolved = resolveSync();
      creds = {
        clientId: resolved.ZOHO_BOOKS_ID,
        clientSecret: resolved.ZOHO_BOOKS_SECRET,
        refreshToken: resolved.ZOHO_BOOKS_REFRESH,
        orgId: ORG_ID,
      };
    }
  } catch (e) {
    console.error('  Cannot resolve Zoho credentials:', e.message.substring(0, 80));
    console.error('  Set ZOHO_BOOKS_ID, ZOHO_BOOKS_SECRET, ZOHO_BOOKS_REFRESH env vars or ensure AWS CLI / Docker fleet is available.');
    process.exit(1);
  }

  // Get OAuth token
  const tokenResp = await fetch('https://accounts.zoho.com/oauth/v2/token', {
    method: 'POST',
    body: new URLSearchParams({
      client_id: creds.clientId,
      client_secret: creds.clientSecret,
      refresh_token: creds.refreshToken,
      grant_type: 'refresh_token',
    }),
  });
  if (!tokenResp.ok) {
    console.error('  OAuth failed:', await tokenResp.text());
    process.exit(1);
  }
  const tokenData = await tokenResp.json();
  const token = tokenData.access_token;
  console.log(`  Token obtained (expires in ${tokenData.expires_in_sec || 3600}s)`);

  const BASE_URL = 'https://www.zohoapis.com/books/v3';
  let updated = 0, failed = 0;

  for (const t of matched) {
    const accountId = CATEGORY_ACCT_IDS[t.suggestedCategory];
    if (!accountId) {
      console.log(`  [SKIP] No account ID for category: ${t.suggestedCategory}`);
      continue;
    }

    // Create expense via POST /expenses with link to the uncategorized bank transaction
    // This works for credit card transactions where categorize endpoint fails
    const expenseUrl = `${BASE_URL}/expenses?organization_id=${ORG_ID}`;
    const paidThroughAccountId = t.account_slug === 'RBC-INTERSITE' ? '93310000000100019' : '93310000000100013';
    const body = JSON.stringify({
      account_id: accountId,
      amount: Math.abs(t.amount),
      description: (t.payee || t.description || t.suggestedCategory).substring(0, 200),
      paid_through_account_id: paidThroughAccountId,
      transaction_id: t.zoho_transaction_id,
    });

    try {
      const resp = await fetch(expenseUrl, {
        method: 'POST',
        headers: {
          Authorization: `Zoho-oauthtoken ${token}`,
          'Content-Type': 'application/json',
        },
        body,
      });
      const data = await resp.json();
      if (data.code === 0) {
        console.log(`  ✓ ${t.account} | $${t.amount.toFixed(2).padStart(8)} | ${t.payee.padEnd(25)} → ${t.suggestedCategory}`);
        updated++;
      } else if (data.code === 57) {
        console.log(`  ✗ ${t.account} | $${t.amount.toFixed(2).padStart(8)} | ${t.payee.padEnd(25)} → FAIL: auth error - need fullaccess.all scope`);
        failed++;
      } else {
        console.log(`  ✗ ${t.account} | $${t.amount.toFixed(2).padStart(8)} | ${t.payee.padEnd(25)} → FAIL: ${data.message || data.code}`);
        failed++;
      }
    } catch (err) {
      console.log(`  ✗ ${t.account} | $${t.amount.toFixed(2).padStart(8)} | ${t.payee.padEnd(25)} → ERROR: ${err.message}`);
      failed++;
    }

    await new Promise(r => setTimeout(r, 400));
  }

  console.log(`\n  Updated: ${updated}, Failed: ${failed}`);
  console.log('\nDone.');
}

main().catch(err => { console.error(`\nFATAL: ${err.message}`); process.exit(1); });
