import { ZohoAuth } from './zoho-auth.js';
import fs from 'fs';
import path from 'path';
import { writeAuditEntry } from './lib/audit-logger.mjs';

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
const matchManifestPath = args['match-json'] || args['manifest-path'] || '';

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
const BASE = path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity, ec.receipt_dir || '2026 Receipts');
const TEMP = path.join(process.env.USERPROFILE, 'AppData', 'Local', 'Temp', 'opencode');

const MIME = { '.pdf': 'application/pdf', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png' };

let MATCHES;
if (matchManifestPath && fs.existsSync(matchManifestPath)) {
  MATCHES = JSON.parse(fs.readFileSync(matchManifestPath, 'utf8'));
  console.log(`Loaded ${MATCHES.length} matches from ${matchManifestPath}`);
} else {
  MATCHES = [
    { eid: '93310000000237485', file: 'rbc-6258/2026-03-24 - 59.0 - Victor Salmon Skool.com Inc..pdf', note: 'Skool $59 USD' },
    { eid: '93310000000238374', file: 'rbc-6258-ingest/2026.01.25 - mozSEO 315.51 CAD - Receipt-2841-3373.pdf', note: 'MOZ $222.88 USD' },
    { eid: '93310000000214347', file: 'rbc-6258/2025-05-02 - 19.0 - AppSumo.jpg', note: 'AppSumo $19 USD' },
    { eid: '93310000000217414', file: 'rbc-6258-ingest/2025.06.10 - WPForms - 99 USD.pdf', note: 'WPForms $99 USD' },
    { eid: '93310000000233400', file: 'rbc-6258-ingest/Boldsign - Receipt-2598-9860.pdf', note: 'BoldSign $60 USD' },
    { eid: '93310000000225475', file: 'rbc-6258-ingest/2025.11.05 - 59.71 temu towels_68UkSbPDkSpxWjPbjxGM.pdf', note: 'Temu $59.71' },
    { eid: '93310000000206406', file: 'rbc-6258-ingest/2025.11.04 - 193.38 - Home Depot - Replace Mulch.pdf', note: 'Home Depot $193.38' },
    { eid: '93310000000203466', file: 'rbc-6258/2025-07-30 - 73.58 - Ozerty.png', note: 'Ozerty $73.58 USD receipt (adj $50.03 CAD)' },
    { eid: '93310000000234333', file: 'rbc-6258/2025-02-25 - 33.60 - Freedom Mobile.pdf', note: 'Freedom Mobile Feb 25 bill (charged Mar 11)' },
    { eid: '93310000000226328', file: 'rbc-6258/2025-03-25 - 33.60 - Freedom Mobile.pdf', note: 'Freedom Mobile Mar 25 bill (charged Apr 8)' },
  ];
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function attach(auth, expenseId, filePath) {
  const token = await auth.getToken();
  const url = `https://www.zohoapis.com/books/v3/expenses/${expenseId}/receipt?organization_id=${ORG_ID}`;
  const ext = path.extname(filePath).toLowerCase();
  const mime = MIME[ext] || 'application/octet-stream';

  const fileBuffer = fs.readFileSync(filePath);

  const boundary = '----FormBoundary' + Math.random().toString(36).slice(2);
  const cleanName = `receipt_${expenseId}${ext}`;
  const header = `--${boundary}\r\nContent-Disposition: form-data; name="receipt"; filename="${cleanName}"\r\nContent-Type: ${mime}\r\n\r\n`;
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
  if (!uploadOk) throw new Error(`Zoho code ${data.code}: ${data.message}`);
  return true;
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  console.log(`=== Upload ${MATCHES.length} receipts (${entity}) ===`);
  console.log(`Mode: ${dryRun ? 'DRY RUN' : 'LIVE'}\n`);

  for (const m of MATCHES) {
    const fp = path.join(BASE, m.file);
    if (!fs.existsSync(fp)) {
      console.error(`[MISSING] ${m.file}`);
    } else {
      const stat = fs.statSync(fp);
      console.log(`[OK] ${m.note}: ${path.basename(m.file)} (${stat.size} bytes)`);
    }
  }

  if (dryRun) { console.log('\n=== DRY RUN COMPLETE ==='); return; }

  const secrets = JSON.parse(process.env.ZOHO_SECRETS);
  const auth = new ZohoAuth({
    clientId: secrets.ZOHO_BOOKS_ID,
    clientSecret: secrets.ZOHO_BOOKS_SECRET,
    refreshToken: secrets.ZOHO_BOOKS_REFRESH
  });
  await auth.getToken();
  console.log();

  let ok = 0, fail = 0;
  for (const m of MATCHES) {
    const fp = path.join(BASE, m.file);
    const ext = path.extname(m.file).toLowerCase();
    const tmpPath = path.join(TEMP, `receipt_${m.eid}${ext}`);

    try {
      fs.copyFileSync(fp, tmpPath);
    } catch (err) {
      console.error(`[SKIP] Can't copy ${m.file}: ${err.message}`);
      continue;
    }

    console.log(`Uploading ${m.note} → ${m.eid}...`);
    try {
      await attach(auth, m.eid, tmpPath);
      console.log(`  [OK]`);
      ok++;
    } catch (err) {
      console.error(`  [FAIL] ${err.message}`);
      fail++;
      break;
    }
    try { fs.unlinkSync(tmpPath); } catch {}
    await sleep(1000);
  }

  console.log(`\n=== Done: ${ok} uploaded, ${fail} failed ===`);
}

main().catch(err => { console.error(`FATAL: ${err.message}`); process.exit(1); });
