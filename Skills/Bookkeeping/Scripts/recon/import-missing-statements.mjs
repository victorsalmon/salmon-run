import https from 'https';
import fs from 'fs';
import { createRequire } from 'module';
import { ZohoAuth } from '../zoho/zoho-auth.js';
const require = createRequire(import.meta.url);
const { getSecret } = require('../shared/lib/get-secret');

const HOME = process.env.HOME || process.env.USERPROFILE || '.';
const ORG_ID = '925048093';
const RBC_ACCT = '93310000000100019';
const MC_ACCT = '93310000000100013';

const base = 'C:/Users/Victor/intersite-docs/Taxes and Bookkeeping/intersite-consulting/2026 Fiscal Year - Bank Statements';
const RBC_SIDECAR = base + '/RBC-INTERSITE/Chequing Statement-6632 2026-05-13.csv';
const MC_SIDECAR = base + '/MC 6241 (6258)/MasterCard Statement-6241 2026-05-11.csv';

function parseCSVLine(line) {
  const result = [];
  let current = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"' && !inQuotes) { inQuotes = true; continue; }
    if (ch === '"' && inQuotes) { inQuotes = false; continue; }
    if (ch === ',' && !inQuotes) { result.push(current.trim()); current = ''; continue; }
    current += ch;
  }
  result.push(current.trim());
  return result;
}

function parseSidecar(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const lines = content.split('\n').filter(l => l.trim() && !l.startsWith('#'));
  if (lines.length < 2) { console.log('No data lines in', filePath); return null; }

  const header = parseCSVLine(lines[0]);
  const dateIdx = header.indexOf('date');
  const payeeIdx = header.indexOf('payee');
  const descIdx = header.indexOf('description');
  const docIdx = header.indexOf('debit_or_credit');
  const amtIdx = header.indexOf('amount');

  const txns = [];
  let startDate = null, endDate = null;
  for (let i = 1; i < lines.length; i++) {
    const parts = parseCSVLine(lines[i]);
    const date = parts[dateIdx]?.trim();
    const payee = parts[payeeIdx]?.trim();
    const desc = parts[descIdx]?.trim() || payee;
    const doc = parts[docIdx]?.trim();
    const amount = parseFloat(parts[amtIdx]?.trim());
    if (!date || !amount || amount <= 0) continue;
    if (!startDate || date < startDate) startDate = date;
    if (!endDate || date > endDate) endDate = date;
    txns.push({ date, debit_or_credit: doc, amount, payee, description: desc });
  }
  return { txns, startDate, endDate };
}

function httpsRequest(url, options, body) {
  return new Promise((resolve, reject) => {
    const req = https.request(url, options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => { try { resolve(JSON.parse(data)); } catch (e) { resolve({ raw: data, error: e.message }); } });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function main() {
  const s = getSecret();
  const auth = new ZohoAuth({
    clientId: s.ZOHO_BOOKS_ID,
    clientSecret: s.ZOHO_BOOKS_SECRET,
    refreshToken: s.ZOHO_BOOKS_REFRESH
  });
  await auth.getToken();
  const headers = auth.headers;
  const apiBase = 'https://www.zohoapis.com/books/v3';

  // Import RBC
  console.log('=== Importing RBC Statement ===');
  const rbc = parseSidecar(RBC_SIDECAR);
  if (!rbc || rbc.txns.length === 0) { console.log('RBC: no transactions to import'); process.exit(1); }
  console.log('RBC:', rbc.txns.length, 'transactions,', rbc.startDate, 'to', rbc.endDate);
  rbc.txns.forEach(t => console.log('  ' + t.date + ' | ' + t.debit_or_credit + ' | $' + t.amount.toFixed(2) + ' | ' + (t.payee || '').substring(0, 50)));

  const rbcBody = JSON.stringify({ account_id: RBC_ACCT, start_date: rbc.startDate, end_date: rbc.endDate, transactions: rbc.txns });
  let result = await httpsRequest(apiBase + '/bankstatements?organization_id=' + ORG_ID, { method: 'POST', headers }, rbcBody);
  console.log('RBC result:', result.message || JSON.stringify(result).substring(0, 500));

  // Import MC
  console.log('\n=== Importing MC Statement ===');
  const mc = parseSidecar(MC_SIDECAR);
  if (!mc || mc.txns.length === 0) { console.log('MC: no transactions to import'); process.exit(1); }
  console.log('MC:', mc.txns.length, 'transactions,', mc.startDate, 'to', mc.endDate);
  mc.txns.forEach(t => console.log('  ' + t.date + ' | ' + t.debit_or_credit + ' | $' + t.amount.toFixed(2) + ' | ' + (t.payee || '').substring(0, 50)));

  const mcBody = JSON.stringify({ account_id: MC_ACCT, start_date: mc.startDate, end_date: mc.endDate, transactions: mc.txns });
  result = await httpsRequest(apiBase + '/bankstatements?organization_id=' + ORG_ID, { method: 'POST', headers }, mcBody);
  console.log('MC result:', result.message || JSON.stringify(result).substring(0, 500));
}

main().catch(e => console.error('Error:', e.message));
