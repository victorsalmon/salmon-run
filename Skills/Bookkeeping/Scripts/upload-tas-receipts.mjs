#!/usr/bin/env node
// PRP Stage 7b — Upload receipt files from TAS rows to matched Zoho expenses.
// Reads TAS-2026.csv rows with zoho_expense_id + receipt_filename,
// uploads each receipt file to the linked Zoho expense.
//
// Used by: Skills/Bookkeeping/books/reconciliation/prp-stage7-cloud-alignment.md § Sub-stage 7b
//
// Usage:
//   node upload-tas-receipts.mjs                          # room-rentals
//   node upload-tas-receipts.mjs --entity intersite-consulting
//   node upload-tas-receipts.mjs --dry-run

import { ZohoAuth } from './zoho-auth.js';
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
const require = createRequire(import.meta.url);
const { parseArgs, loadEntityConfig, sleep } = require('./lib/zoho-common.js');

const args = parseArgs();
const entity = args.entity || 'room-rentals';
const dryRun = process.argv.includes('--dry-run');

const { config, ec } = loadEntityConfig(entity);
const ORG_ID = ec.org_id;
const BOOKS_ROOT = path.join(process.env.USERPROFILE, 'intersite-docs', 'Taxes and Bookkeeping', entity);
const TAS_PATH = path.join(BOOKS_ROOT, 'TAS-2026.csv');
const RECEIPTS_DIR = path.join(BOOKS_ROOT, ec.receipt_dir || '2026 Receipts');

function parseTasCsv(text) {
  const lines = text.trim().split('\n').filter(l => l.trim() && !l.startsWith('#'));
  if (lines.length === 0) return [];
  const header = lines[0].split(',').map(h => h.replace(/^"|"$/g, ''));
  return lines.slice(1).map(l => {
    const vals = [];
    let cur = '', inQ = false;
    for (const ch of l) {
      if (ch === '"') { inQ = !inQ; continue; }
      if (ch === ',' && !inQ) { vals.push(cur.trim()); cur = ''; continue; }
      cur += ch;
    }
    vals.push(cur.trim());
    const obj = {};
    header.forEach((h, i) => obj[h] = (vals[i] || ''));
    return obj;
  });
}

function resolveReceiptPath(relPath) {
  if (!relPath) return null;
  const normalized = relPath.replace(/\\/g, '/');
  // Some paths are relative to books root (e.g. "2026 Receipts/TD/file.pdf")
  if (normalized.startsWith('2026 Receipts/')) {
    return path.join(BOOKS_ROOT, normalized);
  }
  // Most are relative to the receipts directory
  return path.join(RECEIPTS_DIR, normalized);
}

async function attachReceipt(auth, expenseId, filePath) {
  const token = await auth.getToken();
  const url = `https://www.zohoapis.com/books/v3/expenses/${expenseId}/receipt?organization_id=${ORG_ID}`;

  const fileBuffer = fs.readFileSync(filePath);
  let fileName = path.basename(filePath);
  if (fileName.length >= 95) {
    const ext = path.extname(fileName);
    fileName = fileName.substring(0, 85) + ext;
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

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Zoho-oauthtoken ${token}`,
      'Content-Type': `multipart/form-data; boundary=${boundary}`
    },
    body
  });

  const data = await res.json();
  if (data.code !== 0) throw new Error(`Zoho returned code ${data.code}: ${data.message}`);
  return true;
}

async function main() {
  console.log(`=== TAS Receipt Upload (${entity}) ===`);
  console.log(`Mode: ${dryRun ? 'DRY RUN' : 'LIVE'}`);

  // 1. Get auth
  console.log('\n1. Getting credentials...');
  const auth = await ZohoAuth.ensureAuth();
  await auth.getToken();

  // 2. Read TAS
  console.log(`\n2. Reading TAS: ${TAS_PATH}`);
  if (!fs.existsSync(TAS_PATH)) throw new Error(`TAS not found: ${TAS_PATH}`);
  const tas = parseTasCsv(fs.readFileSync(TAS_PATH, 'utf8'));
  console.log(`   ${tas.length} rows`);

  // 3. Filter rows needing upload
  const needUpload = tas.filter(r =>
    r.zoho_expense_id && r.receipt_filename &&
    (!r.zoho_has_receipt || r.zoho_has_receipt === '')
  );
  console.log(`   ${needUpload.length} rows need receipt upload`);

  if (needUpload.length === 0) { console.log('\nNothing to upload.'); return; }

  // 4. Check which files exist and are uploadable (Zoho accepts: pdf, png, jpg, jpeg, gif, bmp)
  const supportedExts = ['.pdf', '.png', '.jpg', '.jpeg', '.gif', '.bmp'];
  const withFiles = needUpload.filter(r => {
    const fp = resolveReceiptPath(r.receipt_filename);
    if (!fp || !fs.existsSync(fp)) {
      console.warn(`   [SKIP] File not found: ${r.receipt_filename}`);
      return false;
    }
    const ext = path.extname(fp).toLowerCase();
    if (!supportedExts.includes(ext)) {
      console.warn(`   [SKIP] Unsupported file type: ${ext} - ${r.receipt_filename}`);
      return false;
    }
    return true;
  });
  console.log(`   ${withFiles.length} with existing receipt files`);

  if (dryRun) {
    console.log('\n--- Dry Run: would upload ---');
    for (const r of withFiles) {
      const fp = resolveReceiptPath(r.receipt_filename);
      console.log(`   ${r.date} $${r.amount} ${r.description.substring(0, 40)}`);
      console.log(`     expense=${r.zoho_expense_id} file=${path.basename(fp)}`);
    }
    console.log(`\n=== DRY RUN: ${withFiles.length} receipts would be uploaded ===`);
    return;
  }

  // 5. Upload
  console.log('\n3. Uploading receipts...');
  let uploaded = 0, errors = 0;

  for (const r of withFiles) {
    const fp = resolveReceiptPath(r.receipt_filename);
    console.log(`   [${uploaded + 1}/${withFiles.length}] expense ${r.zoho_expense_id} <- ${path.basename(fp)}`);
    try {
      await attachReceipt(auth, r.zoho_expense_id, fp);
      console.log(`     [OK]`);
      uploaded++;
    } catch (err) {
      console.error(`     [FAIL] ${err.message}`);
      errors++;
      if (errors >= 10) { console.error('Too many errors, stopping.'); break; }
    }
    await sleep(1000);
  }

  console.log(`\n=== COMPLETE ===`);
  console.log(`Uploaded: ${uploaded}, Errors: ${errors}`);
}

main().catch(err => { console.error(`FATAL: ${err.message}`); process.exit(1); });
