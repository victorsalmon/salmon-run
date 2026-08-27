import { ZohoAuth } from './zoho-auth.js';
import fs from 'fs';
import path from 'path';
import { fetchWithAudit, writeAuditEntry } from './lib/audit-logger.mjs';

function parseArgs() {
  const args = {};
  for (let i = 2; i < process.argv.length; i++) {
    const a = process.argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const v = i + 1 < process.argv.length && !process.argv[i + 1].startsWith('--') ? process.argv[++i] : true;
      args[k] = v;
    }
  }
  return args;
}

const args = parseArgs();
const entity = args.entity || 'intersite-consulting';
const receiptsDir = args['receipts-dir'] || '';

function loadEntityConfig() {
  const scriptDir = path.dirname(process.argv[1]);
  const candidates = [
    path.join(scriptDir, '..', '..', 'cloud-books-entities.json'),
    path.resolve(scriptDir, '..', '..', 'cloud-books-entities.json'),
  ];
  let configPath = null;
  for (const c of candidates) {
    if (fs.existsSync(c)) { configPath = c; break; }
  }
  if (!configPath) throw new Error('cloud-books-entities.json not found');
  return JSON.parse(fs.readFileSync(configPath, 'utf8'));
}

const config = loadEntityConfig();
const ec = config.entities[entity];
if (!ec) throw new Error(`Entity '${entity}' not found in config`);

const ORG_ID = ec.org_id;
let MC_ACCT = null;
if (config.credit_cards) {
  for (const [k, v] of Object.entries(config.credit_cards)) {
    if (v.entity === entity) MC_ACCT = v.account_id;
  }
}

const RECEIPTS_BASE = receiptsDir || path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity, ec.receipt_dir || '2026 Receipts');

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function normalize(s) {
  return (s || '').toLowerCase()
    .replace(/[^a-z0-9]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function vendorFromDesc(desc) {
  const d = desc || '';
  let v = d.replace(/@\s*[\d.]+/, '').trim();
  v = v.replace(/\b(LTD|LIMITED|INC|CORP|ULC|LLC|CO)\b\.?/gi, '').trim();
  v = v.replace(/\b[\d.]+ USD\b/g, '').trim();
  v = v.replace(/\b[A-Z][A-Z]\b$/, '').trim();
  v = v.replace(/\b[A-Z][A-Z]\b(?=\s|$)/, '').trim();
  v = v.replace(/\b\d+\s*[-–]\s*\d+\b/, '').trim();
  return v.replace(/\s+/g, ' ').trim();
}

async function listExpenses(auth) {
  let page = 1, all = [];
  while (true) {
    const url = `https://www.zohoapis.com/books/v3/expenses?organization_id=${ORG_ID}&paid_through_account_id=${MC_ACCT}&page=${page}&per_page=200`;
    const resp = await fetchWithAudit(url, { headers: { Authorization: `Zoho-oauthtoken ${await auth.getToken()}` } }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
    const data = resp.data;
    all = all.concat(data.expenses || []);
    if (!data.page_context || !data.page_context.has_more_page) break;
    page++;
  }
  return all;
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
  fileName = fileName.replace(/[&]/g, 'and').replace(/[<>"|?*]/g, '_');
  const boundary = '----FormBoundary' + Math.random().toString(36).slice(2);
  const header = `--${boundary}\r\nContent-Disposition: form-data; name="receipt"; filename="${fileName}"\r\nContent-Type: application/octet-stream\r\n\r\n`;
  const footer = `\r\n--${boundary}--\r\n`;
  const body = Buffer.concat([
    Buffer.from(header, 'utf8'),
    fileBuffer,
    Buffer.from(footer, 'utf8')
  ]);
  // Known exception: fetchWithAudit's cloneRequest JSON.stringify corrupts Buffer body; audit covered by writeAuditEntry below
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

const RECEIPT_MAP = [
  { fileSearch: 'Moz', vendor: ['moz'], dateTolerance: 1, amount: null, note: 'MOZ $222.88 USD' },
  { fileSearch: 'Skool', vendor: ['skool'], dateTolerance: 2, amount: null, note: 'Skool $59 USD' },
  { fileSearch: 'AppSumo', vendor: ['appsumo'], dateTolerance: 2, amount: null, note: 'AppSumo $52.90 USD' },
  { fileSearch: 'Boldsign', vendor: ['boldsign'], dateTolerance: 2, amount: null, note: 'BoldSign $60 USD' },
  { fileSearch: 'WPForms', vendor: ['wpforms'], dateTolerance: 2, amount: null, note: 'WPForms $99 USD' },
  { fileSearch: 'RECEIPT.pdf', vendor: ['bc registr', 'bc registry', 'prov of bc'], dateTolerance: 2, amount: null, note: 'BC Registry' },
  { fileSearch: 'Bugman', vendor: ['bugman'], dateTolerance: 3, amount: null, note: 'Bugman Pest Control' },
  { fileSearch: 'Namecheap', vendor: ['namecheap', 'name-cheap'], dateTolerance: 2, amount: null, note: 'Namecheap' },
  { fileSearch: 'Squarespace', vendor: ['sqsp', 'squarespace'], dateTolerance: 3, amount: null, note: 'Squarespace' },
  { fileSearch: 'Temu', vendor: ['temu'], dateTolerance: 3, amount: null, note: 'Temu' },
  { fileSearch: 'Clean', vendor: ['clean-it'], dateTolerance: 3, amount: null, note: 'Clean-It All' },
  { fileSearch: 'Food Bank', vendor: ['cofoodbank'], dateTolerance: 3, amount: null, note: 'CoFoodBank' },
  { fileSearch: 'Kilo Code', vendor: ['kilo code', 'kilo'], dateTolerance: 3, amount: null, note: 'Kilo Code $10 USD' },
  { fileSearch: 'Mobil', vendor: ['mobil'], dateTolerance: 3, amount: null, note: 'Mobil' },
  { fileSearch: 'Reinvest', vendor: ['reinvestwealth'], dateTolerance: 5, amount: null, note: 'ReInvestWealth' },
];

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  console.log(`=== FX-Aware Receipt Match (${entity}) ===`);
  console.log(`Mode: ${dryRun ? 'DRY RUN' : 'LIVE'}\n`);

  const secrets = JSON.parse(process.env.ZOHO_SECRETS);
  const auth = new ZohoAuth({
    clientId: secrets.ZOHO_BOOKS_ID,
    clientSecret: secrets.ZOHO_BOOKS_SECRET,
    refreshToken: secrets.ZOHO_BOOKS_REFRESH
  });
  await auth.getToken();

  const allExpenses = await listExpenses(auth);
  const unattached = allExpenses.filter(e => !e.has_attachment);
  console.log(`Found ${unattached.length} expenses without receipts\n`);

  const receiptDir = path.join(RECEIPTS_BASE, 'rbc-6258');
  let files = [];
  try {
    files = fs.readdirSync(receiptDir).filter(f => {
      const ext = path.extname(f).toLowerCase();
      return ['.pdf', '.jpg', '.jpeg', '.png'].includes(ext) && f !== 'non-matching';
    }).map(f => ({ name: f, path: path.join(receiptDir, f) }));
  } catch (e) { console.error(`  [WARN] Could not read rbc-6258/: ${e.message}`); }
  console.log(`Scanned ${files.length} receipt files in rbc-6258/\n`);

  const ingestDir = path.join(RECEIPTS_BASE, 'rbc-6258-ingest');
  let ingestFiles = [];
  try {
    ingestFiles = fs.readdirSync(ingestDir).filter(f => {
      const ext = path.extname(f).toLowerCase();
      return ['.pdf', '.jpg', '.jpeg', '.png'].includes(ext);
    }).map(f => ({ name: f, path: path.join(ingestDir, f) }));
  } catch (e) { console.error(`  [WARN] Could not read rbc-6258-ingest/: ${e.message}`); }
  console.log(`Also scanning ${ingestFiles.length} files in rbc-6258-ingest/\n`);

  const matched = [];
  const unmatched_expenses = [];

  for (const exp of unattached) {
    const eDate = exp.date;
    const eDesc = exp.description || '';
    const eVendor = exp.vendor_name || '';
    const eAmount = exp.total;
    const searchText = normalize(eDesc + ' ' + eVendor);

    let matchFile = null;
    let matchReason = '';

    for (const f of files) {
      const fNorm = normalize(f.name);
      const descWords = searchText.split(/\s+/).filter(w => w.length > 4);
      const matchedWords = descWords.filter(w => fNorm.includes(w) || fNorm.includes(w.replace(/[^a-z0-9]/g, '')));
      if (matchedWords.length >= 1) {
        const fDateMatch = f.name.match(/(\d{4}-\d{2}-\d{2})/);
        if (fDateMatch) {
          const fDate = fDateMatch[1];
          const fTime = new Date(fDate).getTime();
          const eTime = new Date(eDate).getTime();
          if (isNaN(fTime) || isNaN(eTime)) continue;
          const dd = Math.abs((fTime - eTime) / 86400000);
          if (dd <= 5) {
            if (!matchFile || matchedWords.length > (matchReason.split(',').length)) {
              matchFile = f;
              matchReason = `vendor match: ${matchedWords.join(', ')} (date diff ${dd}d)`;
            }
          }
        }
      }
    }

    if (!matchFile) {
      for (const f of ingestFiles) {
        const fNorm = normalize(f.name);
        const descWords = searchText.split(/\s+/).filter(w => w.length > 4);
        const matchedWords = descWords.filter(w => fNorm.includes(w) || fNorm.includes(w.replace(/[^a-z0-9]/g, '')));
        if (matchedWords.length >= 1) {
          const fDateMatch = f.name.match(/(\d{4}.\d{2}.\d{2})/);
          if (fDateMatch) {
            const fDate = fDateMatch[1].replace(/\./g, '-');
            const fTime = new Date(fDate).getTime();
            const eTime = new Date(eDate).getTime();
            if (isNaN(fTime) || isNaN(eTime)) continue;
            const dd = Math.abs((fTime - eTime) / 86400000);
            if (dd <= 10) {
              if (!matchFile || matchedWords.length > (matchReason.split(',').length)) {
                matchFile = f;
                matchReason = `ingest vendor match: ${matchedWords.join(', ')} (date diff ${dd}d)`;
              }
            }
          }
        }
      }
    }

    if (!matchFile) {
      for (const mapEntry of RECEIPT_MAP) {
        if (matchFile) break;
        if (mapEntry.vendor.some(v => searchText.includes(v))) {
          const pattern = normalize(mapEntry.fileSearch);
          for (const f of [...files, ...ingestFiles]) {
            const fNorm = normalize(f.name);
            if (fNorm.includes(pattern)) {
              const fDateMatch = f.name.match(/(\d{4}[\-.]\d{2}[\-.]\d{2})/);
              if (fDateMatch) {
                const fDate = fDateMatch[1].replace(/\./g, '-');
                const fTime = new Date(fDate).getTime();
                const eTime = new Date(eDate).getTime();
                if (isNaN(fTime) || isNaN(eTime)) continue;
                const dd = Math.abs((fTime - eTime) / 86400000);
                if (dd <= mapEntry.dateTolerance) {
                  matchFile = f;
                  matchReason = `manual map: ${mapEntry.fileSearch} (${mapEntry.note}, date diff ${dd}d)`;
                  break;
                }
              }
            }
          }
        }
      }
    }

    if (matchFile) {
      matched.push({ expense: exp, file: matchFile, reason: matchReason });
    } else {
      unmatched_expenses.push(exp);
    }
  }

  console.log('=== MATCHED ===');
  for (const m of matched) {
    console.log(`[MATCH] ${m.expense.date} $${m.expense.total} "${(m.expense.description||'').substring(0,50)}"`);
    console.log(`        → ${m.file.name}`);
    console.log(`        → ${m.reason}`);
    console.log();
  }

  console.log(`=== UNMATCHED: ${unmatched_expenses.length} ===`);
  for (const e of unmatched_expenses) {
    console.log(`${e.date} $${e.total} "${(e.description||e.vendor_name||'').substring(0,60)}"`);
  }

  if (dryRun) {
    console.log(`\n=== DRY RUN COMPLETE ===`);
    console.log(`Would upload ${matched.length} receipts`);
    return;
  }

  console.log(`\n=== UPLOADING ${matched.length} RECEIPTS ===`);
  let uploaded = 0, errors = 0;
  for (const m of matched) {
    const expenseId = m.expense.expense_id;
    const filePath = m.file.path;
    console.log(`  ${m.file.name} → expense ${expenseId}`);
    try {
      await attachReceipt(auth, expenseId, filePath);
      console.log(`    [OK]`);
      uploaded++;
    } catch (err) {
      console.error(`    [FAIL] ${err.message}`);
      errors++;
      break;
    }
    await sleep(1000);
  }
  console.log(`\nUploaded: ${uploaded}, Errors: ${errors}`);
}

main().catch(err => { console.error(`FATAL: ${err.message}`); process.exit(1); });
