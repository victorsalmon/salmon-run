#!/usr/bin/env node
// ⚠️ OAuth RATE LIMIT: Zoho's token endpoint allows ~5 refreshes per 15-30 min.
// Get ONE token at session start, cache it, reuse for ALL calls. See known-issues.md.
// Sync TAS zoho_expense_id + zoho_has_receipt from Zoho API.
// Idempotent: safe to re-run. Adds missing columns, updates dates.
//
// Usage:
//   node Sync-TasReceiptStatus.mjs                            # both entities
//   node Sync-TasReceiptStatus.mjs --entity intersite-consulting
//   node Sync-TasReceiptStatus.mjs --entity room-rentals

import fs from 'fs';
import os from 'os';
import path from 'path';
import { createRequire } from 'module';
import { fetchWithAudit } from '../shared/lib/audit-logger.mjs';
import { ZohoRateLimiter } from './zoho-rate-limiter.mjs';
import { resolveSync } from './resolve-zoho-creds.mjs';

const require = createRequire(import.meta.url);
const { ZohoAuth } = require('./zoho-auth.js');

function parseCliArgs() {
  const args = process.argv.slice(2);
  const opts = { repoRoot: null, entity: null };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--repo-root') { opts.repoRoot = path.resolve(args[++i]); continue; }
    if (args[i] === '--entity') { opts.entity = args[++i]; continue; }
  }
  return opts;
}
const CLI_OPTS = parseCliArgs();

const REPO_ROOT = (() => {
  let root;
  if (CLI_OPTS.repoRoot) {
    root = path.resolve(CLI_OPTS.repoRoot);
  } else if (process.env.REPO_ROOT) {
    root = path.resolve(process.env.REPO_ROOT);
  } else {
    const tryPaths = [
      process.env.USERPROFILE ? path.resolve(process.env.USERPROFILE, 'intersite-orchestrator') : null,
      process.env.HOME ? path.resolve(process.env.HOME, 'intersite-orchestrator') : null,
      path.resolve(os.homedir(), 'intersite-orchestrator'),
      path.resolve('.'),
    ].filter(Boolean);
    root = tryPaths.find(p => fs.existsSync(p)) || tryPaths[tryPaths.length - 1];
  }
  if (!fs.existsSync(root)) {
    console.error('  ERROR: repo-root does not exist: ' + root);
    console.error('  Provide --repo-root <path> or set REPO_ROOT env var');
    process.exit(1);
  }
  return root;
})();

const BOOKS_DIR = path.resolve(process.env.USERPROFILE || os.homedir(), 'intersite-docs', 'Taxes and Bookkeeping');
const TODAY = new Date().toISOString().split('T')[0];
const NEW_COL = 'zoho_has_receipt';

function loadEntities() {
  const orgConfigPath = path.resolve(REPO_ROOT, 'Skills/Bookkeeping/_organizations/organizations.json');
  try {
    const raw = fs.readFileSync(orgConfigPath, 'utf8');
    const config = JSON.parse(raw);
    return (config.organizations || [])
      .filter(o => o.zoho)
      .map(o => ({
        slug: o.slug || o.id,
        orgId: o.zoho.orgId,
        tasRelPath: o.id === 'intersite-consulting-inc'
          ? 'intersite-consulting/TAS-2026.csv'
          : 'room-rentals/TAS-2026.csv',
        accounts: o.zoho.accounts || [],
      }));
  } catch (e) {
    console.warn('  WARN: Could not load organizations.json: ' + e.message.substring(0, 80));
    console.warn('  Falling back to env vars for entity config');
    return [];
  }
}

const ENTITIES = loadEntities();

// ── CSV helpers ──────────────────────────────────────────────────────────

function parseCsvLine(line) {
  const vals = []; let cur = '', inQ = false;
  for (const ch of line) {
    if (ch === '"') { inQ = !inQ; continue; }
    if (ch === ',' && !inQ) { vals.push(cur.trim()); cur = ''; continue; }
    cur += ch;
  }
  vals.push(cur.trim());
  return vals;
}

function toCsvVal(v) {
  const s = (v == null ? '' : String(v));
  if (s.includes(',') || s.includes('"') || s.includes('\n')) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

// ── Date / amount helpers ────────────────────────────────────────────────

function parseDate(d) {
  if (!d) return '';
  let m = d.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (m) return m[1] + '-' + m[2] + '-' + m[3];
  m = d.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (m) return m[3] + '-' + m[1].padStart(2,'0') + '-' + m[2].padStart(2,'0');
  return d;
}

function parseAmount(n) {
  if (n == null) return 0;
  return Math.abs(parseFloat(String(n).replace(/[$,]/g, '')) || 0);
}

function normalizeVendor(name) {
  if (!name) return '';
  return name.toLowerCase()
    .replace(/vendu par\s*/i, '').replace(/\/\s*vendu par\s*/i, '')
    .replace(/seller profile\)?/i, '').replace(/[()]/g, '')
    .replace(/\.$/, '').replace(/\b(inc|ltd|llc|ulc|corp)\.?$/i, '').trim();
}

function vendorScore(tasVendor, expVendor) {
  if (!tasVendor || !expVendor) return 0;
  const a = normalizeVendor(tasVendor);
  const b = normalizeVendor(expVendor);
  if (a === b) return 100;
  if (a.includes(b) || b.includes(a)) return 80;
  const aWords = a.split(/\s+/);
  const bWords = b.split(/\s+/);
  const common = aWords.filter(w => bWords.includes(w)).length;
  return common > 0 ? Math.round((common / Math.max(aWords.length, bWords.length)) * 60) : 0;
}

function getExpenseAmount(exp) {
  return parseFloat(exp.bcy_total || exp.total || exp.amount || 0);
}

// ── Zoho API ─────────────────────────────────────────────────────────────

async function fetchAllExpenses(auth, orgId, accountId, limiter) {
  const all = []; let page = 1, hasMore = true;
  while (hasMore) {
    await limiter.batchWait();
    const url = 'https://www.zohoapis.com/books/v3/expenses?organization_id=' + orgId + '&paid_through_account_id=' + accountId + '&page=' + page + '&per_page=200&sort_column=date&sort_order=D';
    let resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
    if (resp.status === 429) {
      const maxRetries = 3;
      for (let attempt = 0; attempt < maxRetries; attempt++) {
        const delay = Math.pow(2, attempt) * 1000;
        console.warn('  Rate limited (429) — retry ' + (attempt + 1) + '/' + maxRetries + ' after ' + delay + 'ms');
        await new Promise(r => setTimeout(r, delay));
        await limiter.batchWait();
        resp = await fetchWithAudit(url, { headers: auth.headers }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
        if (resp.ok) break;
        if (resp.status !== 429 && attempt === maxRetries - 1) break;
      }
    }
    if (!resp.ok) throw new Error('Expenses API ' + resp.status + ': ' + JSON.stringify(resp.data).substring(0, 200));
    all.push(...(resp.data.expenses || []));
    hasMore = resp.data.page_context && resp.data.page_context.has_more_page;
    page++;
    if (page > 25) break;
  }
  return all;
}

// ── Enrichment logic (ported from Enrich-TasWithExpenseIds.mjs) ──────────

function indexExpenses(expenses) {
  const idx = {};
  const secondaryIdx = {};
  for (const exp of expenses) {
    const dt = parseDate(exp.date);
    if (!dt) continue;
    const amt = Math.abs(getExpenseAmount(exp));
    const key = dt + '|' + amt.toFixed(2);
    if (!idx[key]) idx[key] = [];
    idx[key].push(exp);

    // Secondary index by vendor name + amount for tie-breaking
    const vName = normalizeVendor(exp.vendor_name || exp.description || '');
    if (vName) {
      const secKey = key + '|' + vName;
      if (!secondaryIdx[secKey]) secondaryIdx[secKey] = [];
      secondaryIdx[secKey].push(exp);
    }
  }
  // Augment the primary index with secondary lookup available
  idx._secondary = secondaryIdx;
  return idx;
}

function matchExpense(tasDate, tasAmount, tasDesc, expenseIndex) {
  const amt = parseAmount(tasAmount);
  const dt = parseDate(tasDate);
  if (!dt) return null;

  const exactKey = dt + '|' + amt.toFixed(2);
  const candidates = expenseIndex[exactKey];

  // Try secondary (vendor-normalized) key first for tie-breaking
  if (candidates && candidates.length > 1 && tasDesc) {
    const tasNorm = normalizeVendor(tasDesc);
    if (tasNorm) {
      const secKey = exactKey + '|' + tasNorm;
      const secCandidates = expenseIndex._secondary && expenseIndex._secondary[secKey];
      if (secCandidates && secCandidates.length === 1) {
        return { expense_id: secCandidates[0].expense_id, score: 95, match_type: 'exact' };
      }
    }
  }

  if (candidates && candidates.length === 1) {
    return { expense_id: candidates[0].expense_id, score: 100, match_type: 'exact' };
  }
  if (candidates && candidates.length > 1) {
    const tasNorm = normalizeVendor(tasDesc);
    let best = null, bestScore = 0;
    let ambiguous = [];
    for (const exp of candidates) {
      const ev = normalizeVendor(exp.vendor_name || '');
      const ed = normalizeVendor(exp.description || '');
      const s = vendorScore(tasNorm, ev || ed);
      if (s > bestScore) { bestScore = s; best = exp; }
      ambiguous.push({ expense_id: exp.expense_id, vendor: exp.vendor_name, description: exp.description, score: s });
    }
    if (best && bestScore >= 50) return { expense_id: best.expense_id, score: bestScore, match_type: 'exact (vendor tiebreak)' };
    return { expense_id: null, score: 0, match_type: 'ambiguous', candidates: ambiguous };
  }

  for (const delta of [-1, 1]) {
    const adj = new Date(dt);
    adj.setDate(adj.getDate() + delta);
    const adjKey = adj.toISOString().split('T')[0] + '|' + amt.toFixed(2);
    const adjCandidates = expenseIndex[adjKey];
    if (adjCandidates && adjCandidates.length > 0) {
      return { expense_id: adjCandidates[0].expense_id, score: 70, match_type: 'fuzzy \u00b11d' };
    }
  }
  for (const delta of [-2, 2]) {
    const adj = new Date(dt);
    adj.setDate(adj.getDate() + delta);
    const adjKey = adj.toISOString().split('T')[0] + '|' + amt.toFixed(2);
    const adjCandidates = expenseIndex[adjKey];
    if (adjCandidates && adjCandidates.length > 0) {
      return { expense_id: adjCandidates[0].expense_id, score: 50, match_type: 'fuzzy \u00b12d' };
    }
  }
  for (const tolerance of [0.05, 0.10]) {
    const fuzzyKey = dt + '|' + (amt - tolerance).toFixed(2);
    const fuzzyCandidates = expenseIndex[fuzzyKey];
    if (fuzzyCandidates && fuzzyCandidates.length > 0) {
      return { expense_id: fuzzyCandidates[0].expense_id, score: 40, match_type: 'fuzzy \u00b1$' + tolerance.toFixed(2) };
    }
    const fuzzyKey2 = dt + '|' + (amt + tolerance).toFixed(2);
    const fuzzyCandidates2 = expenseIndex[fuzzyKey2];
    if (fuzzyCandidates2 && fuzzyCandidates2.length > 0) {
      return { expense_id: fuzzyCandidates2[0].expense_id, score: 40, match_type: 'fuzzy \u00b1$' + tolerance.toFixed(2) };
    }
  }
  return null;
}

// ── Main sync ────────────────────────────────────────────────────────────

async function sync(entity) {
  console.log('\n=== ' + entity.slug + ' ===');

  const tasPath = path.resolve(BOOKS_DIR, entity.tasRelPath);
  if (!fs.existsSync(tasPath)) { console.error('  TAS not found: ' + tasPath); return; }

  // 1. Resolve creds via shared resolver
  const rawCreds = resolveSync();
  const creds = {
    clientId: rawCreds.ZOHO_BOOKS_ID,
    clientSecret: rawCreds.ZOHO_BOOKS_SECRET,
    refreshToken: rawCreds.ZOHO_BOOKS_REFRESH,
  };

  const auth = ZohoAuth.getInstance(creds);
  await auth.getToken();
  const limiter = new ZohoRateLimiter({ minGapMs: 350, batchSleepMs: 2000 });

  // 2. Fetch all expenses from Zoho
  const allExpenses = [];
  for (const acct of entity.accounts) {
    const exps = await fetchAllExpenses(auth, entity.orgId, acct.id, limiter);
    allExpenses.push(...exps);
    console.log('  ' + acct.label + ': ' + exps.length + ' expenses');
  }
  console.log('  Total: ' + allExpenses.length + ' expenses');

  const expenseIndex = indexExpenses(allExpenses);
  const attachmentMap = {};
  for (const e of allExpenses) attachmentMap[e.expense_id] = !!e.has_attachment;
  const attachCount = Object.values(attachmentMap).filter(Boolean).length;
  console.log('  With receipt: ' + attachCount);

  // 3. Read TAS (strip any UTF-8 BOM defensively)
  const raw = fs.readFileSync(tasPath, 'utf8').replace(/^\uFEFF/, '');
  const lines = raw.split('\n');
  const comments = [];
  let headerLine = '', headerIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.trim().startsWith('#')) { comments.push(l); continue; }
    if (l.trim() === '') continue;
    headerLine = l; headerIdx = i; break;
  }

  const rawHeaders = parseCsvLine(headerLine);
  let headers = rawHeaders.map(h => h.replace(/^"|"$/g, '').trim());

  // Verification gate: TAS must have at least 1 data row and zoho_expense_id column
  const dataRows = [];
  for (let i = headerIdx + 1; i < lines.length; i++) { const l = lines[i].trim(); if (l && !l.startsWith('#')) dataRows.push(l); }
  if (dataRows.length < 1) { console.error('  TAS has no data rows — nothing to sync'); return; }

  const hasExpenseId = headers.indexOf('zoho_expense_id') !== -1;
  const hasReceiptCol = headers.indexOf(NEW_COL) !== -1;
  if (!hasExpenseId) headers = headers.concat(['zoho_expense_id', 'expense_match_type', 'expense_match_score']);
  const expenseIdIdx = headers.indexOf('zoho_expense_id');
  const typeIdx = headers.indexOf('expense_match_type');
  const scoreIdx = headers.indexOf('expense_match_score');
  if (!hasReceiptCol) headers.push(NEW_COL);
  const receiptIdx = headers.indexOf(NEW_COL);

  // 4. Parse data rows
  const rows = [];
  for (let i = headerIdx + 1; i < lines.length; i++) {
    const l = lines[i].trim();
    if (!l) continue;
    const vals = parseCsvLine(l);
    const obj = {};
    headers.forEach((h, j) => obj[h] = (vals[j] || '').replace(/^"|"$/g, '').trim());
    rows.push(obj);
  }
  console.log('  TAS rows: ' + rows.length);

  // 5. Enrich & sync
  let exact = 0, fuzzy = 0, noMatch = 0, ambiguous = 0;
  let updatedRec = 0, unchangedRec = 0, matchedExpenses = 0;
  let manualReviewList = [];

  for (const row of rows) {
    const tasDt = row.date || '';
    const tasAmt = row.amount || '';
    const tasPayee = (row.description || '').split('  ')[0] || row.description || '';

    // Enrich zoho_expense_id if empty
    let eid = row.zoho_expense_id;
    if (!eid) {
      const m = matchExpense(tasDt, tasAmt, tasPayee, expenseIndex);
      if (m && m.expense_id) {
        row.zoho_expense_id = m.expense_id;
        row.expense_match_type = m.match_type;
        row.expense_match_score = String(m.score);
        if (m.match_type === 'exact') exact++;
        else fuzzy++;
        eid = m.expense_id;
      } else if (m && m.match_type === 'ambiguous') {
        ambiguous++;
        row.expense_match_type = 'ambiguous';
        row.expense_match_score = '0';
        manualReviewList.push({
          date: tasDt,
          amount: tasAmt,
          description: tasPayee,
          candidates: m.candidates,
        });
      } else {
        noMatch++;
      }
    } else {
      // Verify existing zoho_expense_id still resolves to a valid expense
      const existingExpense = allExpenses.find(e => e.expense_id === eid);
      if (!existingExpense) {
        // Stale ID — re-match
        const m = matchExpense(tasDt, tasAmt, tasPayee, expenseIndex);
        if (m && m.expense_id) {
          row.zoho_expense_id = m.expense_id;
          row.expense_match_type = m.match_type + ' (replaced stale ' + eid + ')';
          row.expense_match_score = String(m.score);
          if (m.match_type === 'exact') exact++;
          else fuzzy++;
          eid = m.expense_id;
        } else {
          row.zoho_expense_id = '';
          row.expense_match_type = 'stale_removed';
          row.expense_match_score = '0';
          eid = null;
          noMatch++;
        }
      } else {
        matchedExpenses++;
      }
    }

    // Sync zoho_has_receipt (skip for ambiguous matches — don't link until resolved)
    if (eid) {
      const hasAttach = attachmentMap[eid];
      const cur = row[NEW_COL] || '';
      if (hasAttach) {
        if (cur !== TODAY) { row[NEW_COL] = TODAY; updatedRec++; }
        else { unchangedRec++; }
      } else {
        if (cur !== '') { row[NEW_COL] = ''; updatedRec++; }
        else { unchangedRec++; }
      }
    }
  }

  // Count rows that were already enriched (had eid before this run)
  console.log('  Already had zoho_expense_id: ' + matchedExpenses);
  if (exact + fuzzy + ambiguous > 0)
    console.log('  Newly matched: ' + exact + ' exact, ' + fuzzy + ' fuzzy, ' + ambiguous + ' ambiguous (manual review), ' + noMatch + ' unmatched');
  console.log('  ' + NEW_COL + ': ' + updatedRec + ' updated, ' + unchangedRec + ' unchanged');
  if (manualReviewList.length > 0) {
    console.log('  Manual review items: ' + manualReviewList.length);
    for (const item of manualReviewList) {
      const candStr = item.candidates.map(c => c.vendor + '(' + c.expense_id + ')').join(', ');
      console.log('    AMBIGUOUS: ' + item.date + ' | ' + item.amount + ' | ' + item.description + ' -> ' + candStr);
    }
  }

  // 5.5. Read and append pipeline warnings
  const warningsPath = path.resolve(path.dirname(tasPath), '.pipeline-warnings.json');
  let pipelineWarnings = [];
  try {
    if (fs.existsSync(warningsPath)) {
      const existing = JSON.parse(fs.readFileSync(warningsPath, 'utf8'));
      pipelineWarnings = pipelineWarnings.concat(existing);
    }
  } catch (e) {
    pipelineWarnings.push({ stage: 'Sync-TasReceiptStatus', severity: 'warning', message: 'Could not parse existing pipeline warnings: ' + e.message.substring(0, 80) });
  }

  const syncWarnings = [];
  if (noMatch > 0) syncWarnings.push({ stage: 'Sync-TasReceiptStatus', severity: 'warning', message: noMatch + ' TAS rows had no matching Zoho expense' });
  if (ambiguous > 0) syncWarnings.push({ stage: 'Sync-TasReceiptStatus', severity: 'warning', message: ambiguous + ' TAS rows had ambiguous Zoho expense matches (manual review needed)' });
  if (manualReviewList.length > 0) syncWarnings.push({ stage: 'Sync-TasReceiptStatus', severity: 'info', message: manualReviewList.length + ' items flagged for manual review' });
  if (syncWarnings.length > 0) {
    pipelineWarnings = pipelineWarnings.concat(syncWarnings);
    console.log('  Pipeline warnings: ' + syncWarnings.length + ' new entries');
    try {
      fs.writeFileSync(warningsPath, JSON.stringify(pipelineWarnings, null, 2) + '\n', 'utf8');
    } catch (e) {
      console.warn('  Could not write pipeline warnings: ' + e.message.substring(0, 80));
    }
  }

  // 6. Rebuild CSV with atomic write
  const hdr = headers.map(h => toCsvVal(h)).join(',');
  const body = rows.map(r => headers.map(h => toCsvVal(r[h] || '')).join(',')).join('\n');
  const output = comments.join('\n') + '\n' + hdr + '\n' + body;

  // Lock to prevent concurrent reads mid-write
  const lockPath = tasPath + '.lck';
  const lockFd = fs.openSync(lockPath, 'wx');
  try {
    // Timestamped backup
    const bakPath = tasPath + '.' + Date.now() + '.bak';
    fs.copyFileSync(tasPath, bakPath);
    console.log('  Backup: ' + bakPath);

    // Write to temp file, then atomic rename
    const tmpPath = tasPath + '.tmp.' + process.pid;
    fs.writeFileSync(tmpPath, output, 'utf8');
    fs.renameSync(tmpPath, tasPath);
    console.log('  Written: ' + tasPath + ' (' + output.length + ' bytes)');
  } finally {
    fs.closeSync(lockFd);
    try { fs.unlinkSync(lockPath); } catch {}
  }
}

async function main() {
  const args = {};
  for (let i = 2; i < process.argv.length; i++) {
    const a = process.argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const v = (i + 1 < process.argv.length && !process.argv[i + 1].startsWith('--')) ? process.argv[++i] : true;
      args[k] = v;
    }
  }

  const entities = args.entity
    ? ENTITIES.filter(e => e.slug === args.entity)
    : ENTITIES;
  if (entities.length === 0) {
    console.error("Unknown entity '" + args.entity + "'. Valid: " + ENTITIES.map(e => e.slug).join(', '));
    process.exit(1);
  }

  for (const entity of entities) await sync(entity);
}

main().catch(e => { console.error('\nFATAL: ' + e.message); process.exit(1); });
