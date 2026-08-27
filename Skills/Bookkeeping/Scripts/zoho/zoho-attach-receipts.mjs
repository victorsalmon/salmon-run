import { ZohoAuth } from './zoho-auth.js';
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { fetchWithAudit, writeAuditEntry } from './lib/audit-logger.mjs';
const require = createRequire(import.meta.url);
const { parseArgs, loadEntityConfig, sleep } = require('../shared/lib/zoho-common.js');

const args = parseArgs();
const entity = args.entity || 'intersite-consulting';
const receiptsDir = args['receipts-dir'] || '';

const { config, ec } = loadEntityConfig(entity);

const ORG_ID = ec.org_id;
let MC_ACCT = null;
if (config.credit_cards) {
  for (const [k, v] of Object.entries(config.credit_cards)) {
    if (v.entity === entity) MC_ACCT = v.account_id;
  }
}

const RECEIPTS_BASE = receiptsDir || path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity, ec.receipt_dir || '2026 Receipts');
const STATE_FILE = '.zoho-attach-state.json';

function parseCsv(text) {
  const lines = text.trim().split('\n');
  const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, '').trim());
  return lines.slice(1).filter(l => l.trim()).map(l => {
    const vals = [];
    let current = '', inQuotes = false;
    for (const ch of l) {
      if (ch === '"') { inQuotes = !inQuotes; continue; }
      if (ch === ',' && !inQuotes) { vals.push(current.trim()); current = ''; continue; }
      current += ch;
    }
    vals.push(current.trim());
    const obj = {};
    headers.forEach((h, i) => obj[h] = (vals[i] || ''));
    obj._line = l;
    return obj;
  });
}

function normalizeVendor(name) {
  if (!name) return '';
  return name.toLowerCase()
    .replace(/vendu par\s*/i, '')
    .replace(/\/\s*vendu par\s*/i, '')
    .replace(/seller profile\)?/i, '')
    .replace(/\(/g, '').replace(/\)/g, '')
    .replace(/\.$/, '')
    .replace(/inc\.?$/, '')
    .replace(/ltd\.?$/, '')
    .replace(/llc\.?$/, '')
    .replace(/ulc\.?$/, '')
    .replace(/corp\.?$/, '')
    .trim();
}

function parseDate(d) {
  if (!d) return '';
  const m = d.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  const m2 = d.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (m2) return `${m2[3]}-${m2[1].padStart(2,'0')}-${m2[2].padStart(2,'0')}`;
  return d;
}

async function fetchAllExpenses(auth) {
  let page = 1;
  let all = [];
  while (true) {
    const url = `https://www.zohoapis.com/books/v3/expenses?organization_id=${ORG_ID}&paid_through_account_id=${MC_ACCT}&page=${page}&per_page=200`;
    const resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
    if (!resp.ok) throw new Error(`Failed to fetch expenses: ${resp.status}`);
    const data = resp.data;
    if (data.code !== 0) throw new Error(`Failed to fetch expenses: ${data.message}`);
    all = all.concat(data.expenses || []);
    if (!data.page_context || !data.page_context.has_more_page) break;
    page++;
  }
  return all;
}

function findMatch(receipt, expenses) {
  const rDate = parseDate(receipt.Date);
  const rAmount = parseFloat(receipt.Amount);
  const rVendor = normalizeVendor(receipt.Vendor || '');

  if (!rDate || !rAmount) return null;

  let best = null;
  let bestScore = 0;

  for (const exp of expenses) {
    if (exp.has_attachment) continue;

    const eDate = exp.date;
    const eAmount = parseFloat(exp.total);
    const eVendor = normalizeVendor(exp.vendor_name || exp.description || '');

    const dd = dateDiffDays(rDate, eDate);
    if (dd === null || Math.abs(dd) > 3) continue;
    const dateScore = Math.max(0, 10 - Math.abs(dd) * 3);

    const ad = Math.abs(rAmount - eAmount);
    const amountScore = ad === 0 ? 10 : ad <= 1 ? 8 : ad <= 2 ? 5 : ad <= 5 ? 2 : 0;
    if (amountScore === 0) continue;

    let vendorScore = 0;
    if (rVendor && eVendor) {
      if (eVendor.includes(rVendor) || rVendor.includes(eVendor)) vendorScore = 5;
      else {
        const rWords = rVendor.split(/\s+/).filter(w => w.length > 3);
        const eWords = eVendor.split(/\s+/).filter(w => w.length > 3);
        const common = rWords.filter(w => eWords.some(ew => ew.includes(w) || w.includes(ew)));
        vendorScore = Math.min(5, common.length * 2);
      }
    }

    const totalScore = dateScore + amountScore + vendorScore;
    if (totalScore > bestScore) {
      bestScore = totalScore;
      best = { expense: exp, score: totalScore, dateDiff: dd, amountDiff: ad };
    }
  }

  if (bestScore >= 10) return best;
  return null;
}

function dateDiffDays(d1, d2) {
  const p1 = parseDate(d1);
  const p2 = parseDate(d2);
  if (!p1 || !p2) return null;
  const t1 = new Date(p1).getTime();
  const t2 = new Date(p2).getTime();
  if (isNaN(t1) || isNaN(t2)) return null;
  return (t1 - t2) / 86400000;
}

async function attachReceipt(auth, expenseId, filePath) {
  const token = await auth.getToken();
  const url = `https://www.zohoapis.com/books/v3/expenses/${expenseId}/receipt?organization_id=${ORG_ID}`;

  const fileBuffer = fs.readFileSync(filePath);
  let fileName = path.basename(filePath);
  if (fileName.length >= 95) {
    const ext = path.extname(fileName);
    const base = path.basename(fileName, ext);
    fileName = base.substring(0, 85) + ext;
  }
  fileName = fileName.replace(/[&]/g, 'and').replace(/[<>"|?*]/g, '_').replace(/\.(?=\.)/g, '');

  const boundary = '----FormBoundary' + Math.random().toString(36).slice(2);
  const header = `--${boundary}\r\nContent-Disposition: form-data; name="receipt"; filename="${fileName}"\r\nContent-Type: application/octet-stream\r\n\r\n`;
  const footer = `\r\n--${boundary}--\r\n`;
  const body = Buffer.concat([
    Buffer.from(header, 'utf8'),
    fileBuffer,
    Buffer.from(footer, 'utf8')
  ]);

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Zoho-oauthtoken ${token}`,
      'Content-Type': `multipart/form-data; boundary=${boundary}`
    },
    body
  });

  const data = await res.json();
  const uploadOk = data.code === 0;
  writeAuditEntry({
    ts: new Date().toISOString(),
    domain: 'Bookkeeper',
    action: 'zoho:expense:upload-attachment',
    req: { method: 'POST', url },
    res: { status: res.status, code: data.code, upload_ok: uploadOk },
  });
  if (!uploadOk) throw new Error(`Zoho returned code ${data.code}: ${data.message}`);
  return true;
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');

  console.log(`=== ${MC_ACCT ? 'MC' : ''} Receipt Attachment (${entity}) ===`);
  console.log(`Mode: ${dryRun ? 'DRY RUN' : 'LIVE'}`);

  console.log('\n1. Getting Zoho credentials...');
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();

  console.log('2. Fetching MC expenses from Zoho...');
  const expenses = await fetchAllExpenses(auth);
  console.log(`   Found ${expenses.length} expenses`);

  const attachable = expenses.filter(e => !e.has_attachment);
  const attached = expenses.filter(e => e.has_attachment);
  console.log(`   ${attachable.length} without receipt, ${attached.length} with receipt`);

  let state = { completed: [], failed: [] };
  try {
    const raw = fs.readFileSync(STATE_FILE, 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      if (!Array.isArray(parsed.completed)) parsed.completed = [];
      if (!Array.isArray(parsed.failed)) parsed.failed = [];
      state = parsed;
    }
  } catch {}

  console.log('\n3. Reading manifest...');
  const manifestPath = path.join(RECEIPTS_BASE, 'manifest.csv');
  if (!fs.existsSync(manifestPath)) throw new Error(`Manifest not found: ${manifestPath}`);
  const manifest = parseCsv(fs.readFileSync(manifestPath, 'utf8'));
  console.log(`   ${manifest.length} items in manifest`);

  const matchedReceipts = manifest.filter(r =>
    r.Destination && r.Destination.startsWith('rbc-6258/') && !r.Destination.includes('non-matching')
  );
  console.log(`   ${matchedReceipts.length} matched receipts in rbc-6258/`);

  console.log('\n4. Matching receipts to expenses...');
  const matches = [];
  const unmatched = [];
  const usedExpenseIds = new Set();
  for (const receipt of matchedReceipts) {
    const match = findMatch(receipt, attachable);
    if (match && match.score >= 13) {
      if (usedExpenseIds.has(match.expense.expense_id)) {
        console.warn(`   [DUP] ${receipt.Vendor?.substring(0,30)} $${receipt.Amount} -> expense ${match.expense.expense_id} already matched`);
        continue;
      }
      usedExpenseIds.add(match.expense.expense_id);
      matches.push({ receipt, match });
    } else {
      unmatched.push(receipt);
    }
  }

  console.log(`   ${matches.length} matches found`);
  console.log(`   ${unmatched.length} unmatched receipts`);

  const byScore = {};
  for (const m of matches) {
    const s = m.match.score;
    byScore[s] = (byScore[s] || 0) + 1;
  }
  console.log('\nScore distribution:');
  for (const s of Object.keys(byScore).sort((a,b) => a-b)) {
    console.log(`   score ${s}: ${byScore[s]} matches`);
  }

  const highConf = matches.filter(m => m.match.score >= 16);
  const medConf = matches.filter(m => m.match.score >= 13 && m.match.score < 16);

  if (highConf.length > 0) {
    console.log(`\n--- High Confidence (score >= 16) --- ${highConf.length} ---`);
    for (const m of highConf) {
      console.log(`   ${m.receipt.Date} $${m.receipt.Amount} ${(m.receipt.Vendor || '?').substring(0, 35)}`);
      console.log(`     -> ${m.match.expense.date} $${m.match.expense.total} "${(m.match.expense.description || '').substring(0, 50)}" [${m.match.score}]`);
    }
  }
  if (medConf.length > 0) {
    console.log(`\n--- Medium Confidence (score 13-15) --- ${medConf.length} ---`);
    for (const m of medConf) {
      console.log(`   ${m.receipt.Date} $${m.receipt.Amount} ${(m.receipt.Vendor || '?').substring(0, 35)}`);
      console.log(`     -> ${m.match.expense.date} $${m.match.expense.total} "${(m.match.expense.description || '').substring(0, 50)}" [${m.match.score}]`);
    }
  }

  if (unmatched.length > 0) {
    console.log(`\n--- Unmatched: ${unmatched.length} ---`);
    const withDate = unmatched.filter(r => r.Date);
    const withoutDate = unmatched.filter(r => !r.Date);
    console.log(`   With date: ${withDate.length}, Without date: ${withoutDate.length}`);
    if (withDate.length > 0) {
      console.log('   First 15 with date:');
      for (const r of withDate.slice(0, 15)) {
        console.log(`   ${r.Date} $${r.Amount} ${(r.Vendor || '?').substring(0, 40)}`);
      }
    }
  }

  if (dryRun) {
    console.log('\n=== DRY RUN COMPLETE ===');
    console.log(`Would attach ${matches.length} receipts`);
    return;
  }

  console.log('\n5. Scanning directory for actual receipt files...');
  const receiptDir = path.join(RECEIPTS_BASE, 'rbc-6258');
  const diskFiles = [];
  for (const f of fs.readdirSync(receiptDir)) {
    const fullPath = path.join(receiptDir, f);
    if (fs.statSync(fullPath).isFile()) {
      const lower = f.toLowerCase();
      const noSpecial = lower.replace(/[^a-z0-9]/g, '');
      const noTrailingZeros = lower.replace(/(\d+)\.(\d*?)0+(\D|$)/g, (m, before, after, rest) => {
        return after === '' ? `${before}${rest}` : `${before}.${after}${rest}`;
      }).replace(/[^a-z0-9]/g, '');
      const amount = (f.match(/(\d+\.\d+)/) || [])[0];
      const vendor = lower.replace(/^[\d\s\-\.]+/, '').trim();
      diskFiles.push({
        name: f,
        path: fullPath,
        keys: new Set([noSpecial, noTrailingZeros]),
        amount,
        vendor
      });
    }
  }
  console.log(`   ${diskFiles.length} files on disk`);

  function resolveFile(receipt) {
    const candidates = [
      receipt.RenamedFilename,
      receipt.OriginalFilename,
    ];
    for (const name of candidates) {
      if (!name) continue;
      for (const dest of ['rbc-6258', 'rbc-6258/non-matching']) {
        const fp = path.join(RECEIPTS_BASE, dest, path.basename(name));
        if (fs.existsSync(fp)) return fp;
      }
      const searchKey = path.basename(name).toLowerCase().replace(/[^a-z0-9]/g, '');
      const searchKeyTrim = path.basename(name).toLowerCase()
        .replace(/(\d+)\.(\d*?)0+(\D|$)/g, (m, before, after, rest) => {
          return after === '' ? `${before}${rest}` : `${before}.${after}${rest}`;
        }).replace(/[^a-z0-9]/g, '');
      for (const df of diskFiles) {
        if (df.keys.has(searchKey) || (searchKeyTrim !== searchKey && df.keys.has(searchKeyTrim))) {
          return df.path;
        }
      }
      const receiptAmount = receipt.Amount;
      const receiptVendor = (receipt.Vendor || '').toLowerCase().replace(/[^a-z]/g, '');
      const matched = [];
      for (const df of diskFiles) {
        if (receiptAmount && df.amount === receiptAmount.toString()) {
          const dfVendor = df.vendor.replace(/[^a-z]/g, '');
          if (receiptVendor && dfVendor) {
            if (dfVendor.includes(receiptVendor) || receiptVendor.includes(dfVendor)) {
              matched.push(df);
            }
          }
        }
      }
      if (matched.length > 0) {
        const extRank = { '.pdf': 3, '.jpg': 2, '.jpeg': 2, '.png': 2, '.csv': 1, '.md': 0 };
        matched.sort((a, b) => (extRank[path.extname(a.path).toLowerCase()] || 0) - (extRank[path.extname(b.path).toLowerCase()] || 0));
        return matched[matched.length - 1].path;
      }
    }
    return null;
  }

  console.log('\n6. Attaching receipts...');
  let uploaded = 0, skipped = 0, errors = 0;

  for (const m of matches) {
    const filename = m.receipt.RenamedFilename || m.receipt.OriginalFilename;
    const filepath = resolveFile(m.receipt);
    const expenseId = m.match.expense.expense_id;

    if (state.completed.includes(expenseId)) { skipped++; continue; }

    if (!filepath) {
      console.warn(`   [WARN] File not found: ${filename}`);
      skipped++;
      continue;
    }

    console.log(`   ${path.basename(filename)} -> expense ${expenseId}`);
    try {
      await attachReceipt(auth, expenseId, filepath);
      console.log(`     [OK]`);
      state.completed.push(expenseId);
      fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
      uploaded++;
    } catch (err) {
      console.error(`     [FAIL] ${err.message}`);
      state.failed.push({ expenseId, filename, error: err.message });
      fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
      errors++;
      break;
    }
    await sleep(800);
  }

  console.log(`\n=== COMPLETE ===`);
  console.log(`Uploaded: ${uploaded}, Skipped: ${skipped}, Errors: ${errors}`);
}

main().catch(err => { console.error(`FATAL: ${err.message}`); process.exit(1); });

