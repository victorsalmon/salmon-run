const fs = require('fs');
const path = require('path');
const { ZohoAuth } = require('./zoho-auth');
const { parseArgs, loadEntityConfig, sleep } = require('../shared/lib/zoho-common');

const args = parseArgs();
const entity = args.entity || 'intersite-consulting';
const csvDir = args['csv-dir'] || '';
const manifestName = args.manifest || '';

const { config, ec } = loadEntityConfig(entity);

const ORG_ID = ec.org_id;

let RBC_ACCT = [], MC_ACCT = [];
if (config.bank_accounts) {
  for (const [k, v] of Object.entries(config.bank_accounts)) {
    if (v && v.entity === entity && v.account_id) RBC_ACCT.push(v.account_id);
  }
}
if (config.credit_cards) {
  for (const [k, v] of Object.entries(config.credit_cards)) {
    if (v && v.entity === entity && v.account_id) MC_ACCT.push(v.account_id);
  }
}
const rbcId = RBC_ACCT.length > 0 ? RBC_ACCT[0] : null;
const mcId = MC_ACCT.length > 0 ? MC_ACCT[0] : null;

const INCOME_ACCT = ec.incomeAccount || (ec.accounts && ec.accounts.Income ? ec.accounts.Income : null) || (ec.categories && ec.categories.Income ? ec.categories.Income : null);
const BANK_FEES = ec.categories && ec.categories.BankFees ? ec.categories.BankFees : '93310000000000409';
const CREDIT_CARD_CHARGES = ec.categories && ec.categories.CreditCard ? ec.categories.CreditCard : '93310000000000412';
const OTHER_EXPENSES = ec.categories && ec.categories.Other ? ec.categories.Other : '93310000000000460';
const CIT_PAYABLE = '93310000000138058';
const RBC_CHEQUING = rbcId;

async function getAuth() {
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();
  return auth.headers;
}

function apiUrl(path) { return `https://www.zohoapis.com/books/v3${path}?organization_id=${ORG_ID}`; }
function fixDate(d) { const p = d.split('/'); return `${p[2]}-${p[0].padStart(2,'0')}-${p[1].padStart(2,'0')}`; }

function parseCSV(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  const lines = raw.trim().split('\n');
  const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, '').trim());
  return lines.slice(1).filter(l => l.trim()).map(l => {
    const vals = []; let cur = '', q = false;
    for (const ch of l) { if (ch === '"') { q = !q; continue; } if (ch === ',' && !q) { vals.push(cur.trim()); cur = ''; continue; } cur += ch; }
    vals.push(cur.trim());
    const obj = {}; headers.forEach((h, i) => obj[h] = vals[i] || '');
    return obj;
  });
}

async function main() {
  console.log(`=== Non-Receipt Transactions (${entity}) ===\n`);

  const docsRoot = path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity);
  const bankDir = path.join(docsRoot, '2026 Fiscal Year - Bank Statements');

  let rbcCsvPath, mcCsvPath;
  if (csvDir) {
    rbcCsvPath = path.join(csvDir, manifestName || '2026 Fiscal Year - Intersite Transactions.csv');
    mcCsvPath = path.join(csvDir, manifestName || '2026 Fiscal Year - Intersite MC 6258.csv');
  } else {
    rbcCsvPath = path.join(bankDir, 'RBC-INTERSITE', '2026 Fiscal Year - Intersite Transactions.csv');
    mcCsvPath = path.join(bankDir, 'MC 6241 (6258)', '2026 Fiscal Year - Intersite MC 6258.csv');
  }

  console.log('--- RBC Chequing ---');
  const rbc = parseCSV(rbcCsvPath);

  let count = 0;
  if (!rbcId || !mcId) throw new Error(`Missing account configuration — RBC: ${!!rbcId}, MC: ${!!mcId}`);
  const h = await getAuth();

  for (const txn of rbc) {
    const desc1 = txn['Description 1'].trim();
    const desc2 = txn['Description 2'].trim();
    const amt = parseFloat(txn['CAD$']) || 0;
    const date = fixDate(txn['Transaction Date'].trim());
    const desc = `${desc1} ${desc2}`.trim();
    const descRich = `${desc} — $${Math.abs(amt).toFixed(2)} — ${date}`.trim();

    if (amt === 0) continue;

    if (amt < 0) {
      if (desc1.startsWith('PAD CCRA')) {
        const je = { journal_date: date, reference_number: `CRA-PAD-${date.replace(/-/g, '')}`, description: `CRA corporate income tax payment — ${descRich}`, line_items: [{ account_id: CIT_PAYABLE, debit_or_credit: 'debit', amount: Math.abs(amt) }, { account_id: RBC_CHEQUING, debit_or_credit: 'credit', amount: Math.abs(amt) }] };
        const r = await fetch(apiUrl('/journals'), { method: 'POST', headers: h, body: JSON.stringify(je) });
        const d = await r.json();
        if (d.code !== 0) { console.log(`  [FAIL] ${date} $${amt} PAD CCRA: ${d.message}`); break; }
        console.log(`  [OK] PAD CCRA to CIT Payable: ${date} $${Math.abs(amt)}`);
        count++;
        await sleep(500);
        continue;
      }
      let acctId = OTHER_EXPENSES;
      if (desc1 === 'Monthly fee') acctId = BANK_FEES;
      else if (desc1.startsWith('Misc Payment')) acctId = BANK_FEES;
      else if (desc1.startsWith('e-Transfer sent')) continue;

      const body = { account_id: acctId, paid_through_account_id: rbcId, amount: Math.abs(amt), date, description: descRich, is_billable: false };
      const res = await fetch(apiUrl('/expenses'), { method: 'POST', headers: h, body: JSON.stringify(body) });
      const d = await res.json();
      if (d.code !== 0) { console.log(`  [FAIL] ${date} $${amt} ${desc}: ${d.message}`); break; }
      console.log(`  [OK] RBC debit: ${date} $${Math.abs(amt)} ${desc1}`);
      count++;
      await sleep(500);
    } else {
      let fromAcct = INCOME_ACCT;
      if (desc1 === 'Tax Refund') {
        const je = { journal_date: date, reference_number: `CRA-REFUND-${date.replace(/-/g, '')}`, description: `CRA tax refund — ${descRich}`, line_items: [{ account_id: RBC_CHEQUING, debit_or_credit: 'debit', amount: amt }, { account_id: CIT_PAYABLE, debit_or_credit: 'credit', amount: amt }] };
        const r = await fetch(apiUrl('/journals'), { method: 'POST', headers: h, body: JSON.stringify(je) });
        const d = await r.json();
        if (d.code !== 0) { console.log(`  [FAIL] ${date} $${amt} Tax Refund: ${d.message}`); break; }
        console.log(`  [OK] Tax Refund to CIT Payable: ${date} $${amt}`);
        count++;
        await sleep(500);
        continue;
      }
      const body = { from_account_id: fromAcct, to_account_id: rbcId, transaction_type: 'deposit', amount: amt, date, description: descRich };
      const res = await fetch(apiUrl('/banktransactions'), { method: 'POST', headers: h, body: JSON.stringify(body) });
      const d = await res.json();
      if (d.code !== 0) { console.log(`  [FAIL] ${date} $${amt} ${desc}: ${d.message}`); break; }
      console.log(`  [OK] RBC credit: ${date} $${amt} ${desc1}`);
      count++;
      await sleep(500);
    }
  }

  console.log(`\nRBC: ${count} transactions created`);
  count = 0;

  console.log('\n--- MC (non-receipt items) ---');
  const mc = parseCSV(mcCsvPath);

  const skipPrefixes = ['AMZN Mktp', 'Amazon.ca', 'INTERSERVER.NET', 'REINVESTWEALTH', 'THE HOME DEPOT',
    'KAL-TIRE', 'LORDCO PARTS', 'aliexpress', 'PETRO-CANADA', 'TEMU.COM', 'SQUARESPACE',
    'SQSP*', 'P.SKOOL.COM', 'VISIONS ELECTRONICS', 'NAME-CHEAP.COM',
    'DULUX PAINTS', 'DOLLARAMA', 'VERNON LOCK', 'IMPARK', 'CHV4', 'CANCO',
    'ESSO', 'MOBIL', 'MYCLAW.AI', 'WAVE PRO', 'BITWARDEN', 'BOLDSIGN',
    'ICBC', 'BEST BUY', 'LEGALSHIELD', 'OS1* OZERTY', 'MOZSEO',
    'THE BUGMAN', 'UDEMY', 'WPFORMS', 'FREEDOM MOBILE',
    'PAYPAL *SCIENERBXC6', 'WWW.COFOODBANK.COM',
    'CIVIL RESOLUTION TRIBU', 'PROV OF BC', 'APPSUMO.COM'];

  for (const txn of mc) {
    const desc1 = txn['Description 1'].trim();
    const desc2 = txn['Description 2'].trim();
    const amt = parseFloat(txn['CAD$']) || 0;
    const date = fixDate(txn['Transaction Date'].trim());
    const desc = `${desc1} ${desc2}`.trim();

    if (amt === 0) continue;

    const isPurchase = skipPrefixes.some(p => desc1.startsWith(p));
    const isPayment = desc1.includes('PAYMENT - THANK YOU') || desc1.includes('AUTOMATIC PAYMENT');
    const isInterest = desc1.includes('PURCHASE INTEREST');
    const isCashback = desc1.includes('CASH BACK REWARD');
    const isAdjustment = desc1.includes('SALES DRAFT ADJUSTMENT');

    if (isPurchase && !isInterest && !isCashback && !isAdjustment) continue;

    const mcDescRich = `${desc1} ${desc2} — $${Math.abs(amt).toFixed(2)} — ${date}`.trim();
    if (isPayment) {
      const body = { from_account_id: rbcId, to_account_id: mcId, transaction_type: 'transfer_fund', amount: Math.abs(amt), date, description: mcDescRich };
      const res = await fetch(apiUrl('/banktransactions'), { method: 'POST', headers: h, body: JSON.stringify(body) });
      const d = await res.json();
      if (d.code !== 0) { console.log(`  [FAIL] Payment ${date}: ${d.message}`); break; }
      console.log(`  [OK] Payment transfer: ${date} $${Math.abs(amt)}`);
      count++;
      await sleep(500);
      continue;
    }

    if (isInterest) {
      const body = { account_id: CREDIT_CARD_CHARGES, paid_through_account_id: mcId, amount: Math.abs(amt), date, description: mcDescRich, is_billable: false };
      const res = await fetch(apiUrl('/expenses'), { method: 'POST', headers: h, body: JSON.stringify(body) });
      const d = await res.json();
      if (d.code !== 0) { console.log(`  [FAIL] Interest ${date}: ${d.message}`); break; }
      console.log(`  [OK] Interest: ${date} $${Math.abs(amt)}`);
      count++;
      await sleep(500);
      continue;
    }

    if (isCashback || (amt > 0 && !isPayment)) {
      console.log(`  [SKIP] Credit: ${date} $${amt} ${desc1}`);
      continue;
    }

    if (isAdjustment) {
      console.log(`  [SKIP] Adjustment: ${date} $${amt} ${desc1}`);
      continue;
    }

    const body = { account_id: OTHER_EXPENSES, paid_through_account_id: mcId, amount: Math.abs(amt), date, description: mcDescRich, is_billable: false };
    const res = await fetch(apiUrl('/expenses'), { method: 'POST', headers: h, body: JSON.stringify(body) });
    const d = await res.json();
    if (d.code !== 0) { console.log(`  [FAIL] ${date} $${amt} ${desc}: ${d.message}`); break; }
    console.log(`  [OK] MC other: ${date} $${Math.abs(amt)} ${desc1.substring(0, 40)}`);
    count++;
    await sleep(500);
  }

  console.log(`\nMC other: ${count} transactions created`);
  console.log('\nDone.');
}

main().catch(e => { console.error(e.message); process.exit(1); });

