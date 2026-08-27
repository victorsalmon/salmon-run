#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import os from 'os';

const BOOKS_DIR = path.resolve(process.env.USERPROFILE || os.homedir(), 'intersite-docs', 'Taxes and Bookkeeping');

// ── Config ──────────────────────────────────────────────────────────────

const ENTITIES = {
  'intersite-consulting': {
    orgId: '925048093',
    zohoCsvDir: path.join(BOOKS_DIR, 'intersite-consulting', '2026 Filing', '2026 Bank Statements'),
    receiptDir: path.join(BOOKS_DIR, 'intersite-consulting', '2026 Filing', 'Receipts'),
    zohoAccountIds: {
      'RBC-INTERSITE': { name: 'RBC Intersite (Chequing 6632)', folder: 'RBC-INTERSITE', zohoFile: '2026.06.15-Present - RBC Intersite (Chequing 6632) - Zoho.csv' },
      'MC-6258':       { name: 'MC 6258 (MasterCard 6241)',       folder: 'MC 6241 (6258)', zohoFile: '2026.06.15-Present - MC 6258 (MasterCard 6241) - Zoho.csv' },
    },
  },
};

// Intersite account IDs for categories
const CATEGORY_ACCT_IDS = {
  '[8962] Motor vehicles repairs and maintenance': '93310000000000424',
  '[9150] Tech repair, support, subscriptions, peripherals': '93310000000582161',
  'Office & General Expenses':               '93310000000000400',
  'Repairs and Maintenance':                 '93310000000000457',
  'Professional Fees':                       '93310000000135091',
  'Advertising And Marketing':               '93310000000000403',
  'Bank Fees and Charges':                   '93310000000000409',
  'Credit Card Charges':                     '93310000000000412',
  'Other Expenses':                          '93310000000000460',
  'Lease Expense':                           '93310000000217488',
  'Shareholder Loan':                        '93310000000146154',
  'Income Tax Expense':                      '93310000000297002',
  'Consulting Revenue':                      '93310000000149102',
  'Credit Card Payments':                    '93310000000300002',
  'Exclude':                                 '93310000000161002',
  'Intersite':                               '93310000000100013',
  'Intersite RBC Business Cash Back Mastercard': '93310000000100013',
};

// Vendor keyword rules (mirrors categorization-rules.json for intersite-consulting)
const VENDOR_RULES = [
  { rx: /FREEDOM\s*MOBILE|FONGO/i,                         cat: 'Software & IT Expenses' },
  { rx: /PETRO|SHELL|CHEVRON|CHV\d+|GAS\b|CO-OP|CANCO|SUPER\s*SAVE|ESSO|MOBIL(?!E)/i, cat: '[8962] Motor vehicles repairs and maintenance' },
  { rx: /KAL[-?\s]*TIRE|LORDCO|IMPARK|PARKING/i,           cat: '[8962] Motor vehicles repairs and maintenance' },
  { rx: /ICBC/i,                                           cat: '[8962] Motor vehicles repairs and maintenance' },
  { rx: /SCIENER|ZOHO|INTERSERVER|KILO\s*CODE|ANOMALY|WAVE\s*PRO/i, cat: 'Software & IT Expenses' },
  { rx: /OPENAI|OPENROUTER|STRIPE[.-]?Z|PIXELLA|ROOMIES/i, cat: 'Software & IT Expenses' },
  { rx: /LIGHTSPEED|FREEDOM\s*MOBILE|TELEPHONE/i,          cat: 'Software & IT Expenses' },
  { rx: /MYCLAW|SQUARESPACE|NAMECHEAP|CREATIVE\s*FABRICA|P\.SKOOL/i, cat: 'Software & IT Expenses' },
  { rx: /BITWARDEN|TIDYCAL|BREEZEDOC|APP.?SUMO|WP.?FORMS/i, cat: 'Software & IT Expenses' },
  { rx: /BOLDSIGN|UDEMY/i,                                  cat: 'Software & IT Expenses' },
  { rx: /SQSP\s*\*|MOZSEO|NAME.?CHEAP/i,                   cat: 'Software & IT Expenses' },
  { rx: /REINVESTWEALTH/i,                                  cat: 'Software & IT Expenses' },
  { rx: /LEGALSHIELD/i,                                     cat: 'Professional Fees' },
  { rx: /CIVIL\s*RESOLUTION|BC\s*REGISTR|GOVERNMENT|REGISTRATION/i, cat: 'Professional Fees' },
  { rx: /THE\s*BUGMAN|VERNON\s*LOCK|OZERTY|SALES\s*DRAFT/i, cat: 'Repairs and Maintenance' },
  { rx: /HOME\s*DEPOT|DULUX|VISIONS\s*ELECTRONICS|TEMU/i,  cat: 'Repairs and Maintenance' },
  { rx: /PURCHASE\s*INTEREST/i,                             cat: 'Credit Card Charges' },
  { rx: /STAPLES|BEST\s*BUY|DOLLARAMA/i,                   cat: 'Office & General Expenses' },
  { rx: /AMAZON|AMZN/i,                                     cat: 'Office & General Expenses' },
  { rx: /UPSCALE\s*HAVENS/i,                                cat: 'Bank Fees and Charges' },
  { rx: /PAYPAL/i,                                          cat: 'Other Expenses' },
  { rx: /ALIEXPRESS.*OFFICE|ALIEXPRESS.*SUPPLIES|ALIEXPRESS.*STORAGE|ALIEXPRESS.*HOOKS|ALIEXPRESS.*SEAT|ALIEXPRESS.*FOAM|ALIEXPRESS.*MOP|ALIEXPRESS.*CABLE|ALIEXPRESS.*VELCRO|ALIEXPRESS.*PAGE\s*MARKERS/i, cat: 'Office & General Expenses' },
  { rx: /ALIEXPRESS/i,                                      cat: 'Other Expenses' },
  { rx: /CLEAN-IT\s*ALL|CLEAN-IT/i,                          cat: 'Repairs and Maintenance' },
  { rx: /COFOODBANK|FOOD\s*BANK/i,                          cat: 'Advertising And Marketing' },
  { rx: /MONTHLY\s*FEE|PAY-FILE|ACCOUNT\s*FEE/i,           cat: 'Bank Fees and Charges' },
  { rx: /FACEBOOK|META|GOOGLE\s*ADS/i,                     cat: 'Advertising And Marketing' },
  { rx: /NETFLIX|SPOTIFY/i,                                 cat: 'Office & General Expenses' },
];

// ── Helpers ────────────────────────────────────────────────────────────

function parseCsv(filePath) {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  const lines = raw.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
  if (lines.length < 2) return [];
  const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, '').trim());
  return lines.slice(1).map(l => {
    const vals = []; let cur = '', q = false;
    for (const ch of l) { if (ch === '"') { q = !q; continue; } if (ch === ',' && !q) { vals.push(cur.trim()); cur = ''; continue; } cur += ch; }
    vals.push(cur.trim());
    const obj = {}; headers.forEach((h, i) => obj[h] = vals[i] || '');
    return obj;
  });
}

function loadManifest(entity) {
  const manifestPath = path.join(entity.receiptDir, '_manifest.csv');
  const rows = parseCsv(manifestPath);
  // Build lookup: date|abs_amount -> entries
  const lookup = new Map();
  for (const r of rows) {
    const dt = (r.date || '').trim();
    const amt = parseFloat(r.amount);
    if (!dt || isNaN(amt)) continue;
    const key = `${dt}|${Math.abs(amt).toFixed(2)}`;
    if (!lookup.has(key)) lookup.set(key, []);
    lookup.get(key).push(r);
  }
  return { rows, lookup };
}

function findReceiptMatch(manifest, zDate, zAmount) {
  const zDt = new Date(zDate);
  const zAbs = Math.abs(zAmount);
  
  // Exact match first
  const exactKey = `${zDate}|${zAbs.toFixed(2)}`;
  if (manifest.lookup.has(exactKey)) return manifest.lookup.get(exactKey);
  
  // Fuzzy: ±2 days, ±$0.10
  const matches = [];
  for (const [key, entries] of manifest.lookup) {
    const [rDate, rAmtStr] = key.split('|');
    const rAmt = parseFloat(rAmtStr);
    if (Math.abs(rAmt - zAbs) > 0.1) continue;
    try {
      const rDt = new Date(rDate);
      const diffDays = Math.abs((rDt - zDt) / (1000 * 60 * 60 * 24));
      if (diffDays <= 2) matches.push(...entries);
    } catch {}
  }
  return matches.length > 0 ? matches : null;
}

function categorizeFromVendor(vendorText) {
  const t = (vendorText || '').trim();
  if (!t) return null;
  for (const rule of VENDOR_RULES) {
    if (rule.rx.test(t)) return rule.cat;
  }
  return null;
}

function extractVendorFromFilename(filename) {
  // Format: "YYYY-MM-DD - AMOUNT - VENDOR NAME.pdf" or "ACCOUNT\YYYY-MM-DD - AMOUNT - VENDOR.pdf"
  const base = path.basename(filename.replace(/\\/g, '/'));
  // Remove leading account folder if present
  const parts = base.split(path.sep).pop();
  
  // Try to extract vendor: after second " - " segment
  const match = base.match(/^\d{4}-\d{2}-\d{2}\s*-\s*[\d.]+\s*-\s*(.+)\.\w+$/);
  if (match) return match[1].trim();
  
  // Fallback: use vendor column from manifest
  return null;
}

// ── Main ──────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  const apply = args.includes('--apply');
  const entitySlug = args.includes('--entity') ? args[args.indexOf('--entity') + 1] : 'intersite-consulting';

  const entity = ENTITIES[entitySlug];
  if (!entity) { console.error(`Unknown entity: ${entitySlug}`); process.exit(1); }

  console.log(`=== Zoho Recategorize from Manifest (${entitySlug}) ===`);
  if (apply) console.log('  MODE: APPLY — will update Zoho');
  else console.log('  MODE: Dry-run — no changes made');
  console.log();

  // 1. Load receipt manifest
  console.log('Loading receipt manifest...');
  const manifest = loadManifest(entity);
  console.log(`  ${manifest.rows.length} entries in manifest`);
  console.log();

  // 2. Load Zoho export CSVs
  const uncategorized = [];
  
  for (const [slug, acct] of Object.entries(entity.zohoAccountIds)) {
    const csvPath = path.join(entity.zohoCsvDir, acct.folder, acct.zohoFile);
    if (!fs.existsSync(csvPath)) {
      console.log(`  [SKIP] Zoho CSV not found: ${csvPath}`);
      continue;
    }
    const rows = parseCsv(csvPath);
    console.log(`${acct.name}: ${rows.length} Zoho transactions`);
    
    for (const row of rows) {
      const zCat = row.zoho_category || '';
      if (zCat !== 'Other Expenses') continue;
      const zId = row.zoho_transaction_id || '';
      if (!zId) continue;
      
      const date = row.date || '';
      const amt = row.debit_or_credit?.toLowerCase() === 'credit'
        ? -parseFloat(row.amount || 0)
        : parseFloat(row.amount || 0);
      
      uncategorized.push({
        zoho_transaction_id: zId,
        date, amount: amt,
        bank_account: acct.name,
        account_slug: slug,
      });
    }
  }
  
  console.log(`  ${uncategorized.length} Zoho 'Other Expenses' transactions found`);
  console.log();

  // 3. Match against manifest
  console.log('=== Matching against receipt manifest ===');
  const results = [];
  
  for (const txn of uncategorized) {
    const matches = findReceiptMatch(manifest, txn.date, txn.amount);
    
    if (matches && matches.length > 0) {
      // Use the first match
      const receipt = matches[0];
      const vendorFromFilename = extractVendorFromFilename(receipt.filename || '');
      const vendorText = vendorFromFilename || receipt.vendor || receipt.filename || '';
      const suggestedCat = categorizeFromVendor(vendorText);
      
      results.push({
        ...txn,
        status: 'matched',
        receiptFilename: receipt.filename,
        vendor: vendorText,
        suggestedCategory: suggestedCat || 'Other Expenses',
        currentCategory: 'Other Expenses',
      });
    } else {
      results.push({
        ...txn,
        status: 'unmatched',
        receiptFilename: null,
        vendor: null,
        suggestedCategory: null,
        currentCategory: 'Other Expenses',
      });
    }
  }

  // 4. Report
  const matched = results.filter(r => r.status === 'matched');
  const reclassifiable = matched.filter(r => r.suggestedCategory && r.suggestedCategory !== 'Other Expenses');
  const unchanged = matched.filter(r => !r.suggestedCategory || r.suggestedCategory === 'Other Expenses');
  const unmatched = results.filter(r => r.status === 'unmatched');

  console.log(`  Matched: ${matched.length}`);
  console.log(`    → Can recategorize: ${reclassifiable.length}`);
  console.log(`    → Stay as Other Expenses (review): ${unchanged.length}`);
  console.log(`  Unmatched (no receipt found): ${unmatched.length}`);
  console.log();

  if (matched.length > 0) {
    console.log('=== All matched Other Expenses ===');
    for (const r of matched) {
      const cat = r.suggestedCategory || '(no rule match)';
      console.log(`  ${r.date} | $${r.amount.toFixed(2)} | ${r.bank_account}`);
      console.log(`    Receipt: ${r.receiptFilename}`);
      console.log(`    Vendor:  ${(r.vendor || '').substring(0, 60)}`);
      console.log(`    ${cat === 'Other Expenses' ? '→' : '✓'} ${cat}`);
      console.log();
    }
  }

  if (unmatched.length > 0) {
    console.log('=== Unmatched transactions (no receipt found) ===');
    for (const r of unmatched) {
      console.log(`  ${r.date} | $${r.amount.toFixed(2)} | ${r.bank_account}`);
    }
    console.log();
  }

  // 5. Apply if --apply flag set
  if (apply && reclassifiable.length > 0) {
    console.log('=== Applying updates to Zoho ===');
    
    // Get Zoho creds and token
    const { createRequire } = await import('module');
    const require2 = createRequire(import.meta.url);
    const { execSync } = require2('child_process');
    
    let creds;
    try {
      if (process.env.ZOHO_BOOKS_ID && process.env.ZOHO_BOOKS_SECRET && process.env.ZOHO_BOOKS_REFRESH) {
        creds = {
          clientId: process.env.ZOHO_BOOKS_ID,
          clientSecret: process.env.ZOHO_BOOKS_SECRET,
          refreshToken: process.env.ZOHO_BOOKS_REFRESH,
          orgId: entity.orgId,
        };
      } else {
        // Try Docker container bundle
        const containerId = execSync('docker ps --filter name=FRAD_is-bookkeeping --format "{{.ID}}"', { encoding: 'utf8', timeout: 5000 }).trim();
        const bundleJson = execSync(`docker exec ${containerId} cat /run/secrets/bookkeeping_secrets_bundle`, { encoding: 'utf8', timeout: 10000 });
        const bundle = JSON.parse(bundleJson);
        creds = {
          clientId: bundle.ZOHO_BOOKS_ID,
          clientSecret: bundle.ZOHO_BOOKS_SECRET,
          refreshToken: bundle.ZOHO_BOOKS_REFRESH,
          orgId: entity.orgId,
        };
      }
    } catch (e) {
      console.error('  Cannot resolve Zoho credentials:', e.message.substring(0, 80));
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
    let updated = 0;
    let failed = 0;
    
    for (const r of reclassifiable) {
      const accountId = CATEGORY_ACCT_IDS[r.suggestedCategory];
      if (!accountId) {
        console.log(`  [SKIP] No account ID for category: ${r.suggestedCategory}`);
        continue;
      }
      
      // Try expenses endpoint first (most Zoho 'Other Expenses' are expenses)
      const expenseUrl = `${BASE_URL}/expenses/${r.zoho_transaction_id}?organization_id=${creds.orgId}`;
      const bankUrl = `${BASE_URL}/banktransactions/${r.zoho_transaction_id}?organization_id=${creds.orgId}`;
      
      // Check if it's an expense
      const checkResp = await fetch(expenseUrl, {
        headers: { Authorization: `Zoho-oauthtoken ${token}` },
      });
      const checkData = await checkResp.json();
      
      let url, method, body;
      if (checkData.code === 0 && checkData.expense) {
        // It's an expense — update via PUT /expenses/{id}
        url = expenseUrl;
        method = 'PUT';
        body = JSON.stringify({ account_id: accountId });
      } else {
        // Try banktransaction
        url = bankUrl;
        method = 'PUT';
        body = JSON.stringify({ account_id: accountId });
      }
      
      try {
        const resp = await fetch(url, {
          method,
          headers: {
            Authorization: `Zoho-oauthtoken ${token}`,
            'Content-Type': 'application/json',
          },
          body,
        });
        const data = await resp.json();
        if (data.code === 0) {
          const updatedName = data.expense?.account_name || data.banktransaction?.offset_account_name || r.suggestedCategory;
          console.log(`  ✓ ${r.date} $${r.amount.toFixed(2)} → ${updatedName}`);
          updated++;
        } else {
          console.log(`  ✗ ${r.date} $${r.amount.toFixed(2)} → FAIL: ${data.message}`);
          failed++;
        }
      } catch (err) {
        console.log(`  ✗ ${r.date} $${r.amount.toFixed(2)} → ERROR: ${err.message}`);
        failed++;
      }
      
      await new Promise(r2 => setTimeout(r2, 400));
    }
    
    console.log(`\n  Updated: ${updated}, Failed: ${failed}`);
  }

  console.log('\nDone.');
}

main().catch(err => { console.error(`\nFATAL: ${err.message}`); process.exit(1); });
