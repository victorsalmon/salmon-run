#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

const SUMMARY_CODES = new Set([1599, 2599, 3499, 3620, 3640, 8518, 9367, 9368, 9998, 9999]);

function parseCurrency(val) {
  if (!val) return 0;
  const cleaned = val.replace(/[$,]/g, '').trim();
  if (cleaned.startsWith('(') && cleaned.endsWith(')')) {
    return -parseFloat(cleaned.slice(1, -1));
  }
  return parseFloat(cleaned);
}

export function extractT2S100(inputPath) {
  const content = fs.readFileSync(inputPath, 'utf8');
  const lines = content.split('\n').map(l => l.trim());

  const s100Start = lines.findIndex(l => /balance\s+sheet\s+information/i.test(l));
  const s100End = lines.findIndex((l, i) => i > s100Start && /income\s+statement\s+information|schedule\s+125/i.test(l));

  if (s100Start === -1) throw new Error('Could not find "Balance Sheet Information" section');
  const relevantLines = s100End === -1 ? lines.slice(s100Start) : lines.slice(s100Start, s100End);

  const accounts = [];
  for (let i = 0; i < relevantLines.length; i++) {
    const gifiMatch = relevantLines[i].match(/^(\d{4})$/);
    if (!gifiMatch) continue;

    const gifi = parseInt(gifiMatch[1], 10);
    if (SUMMARY_CODES.has(gifi)) continue;

    const currentYearLine = i + 1 < relevantLines.length ? relevantLines[i + 1] : '';
    const prevYearLine = i + 2 < relevantLines.length ? relevantLines[i + 2] : '';
    const nextNextLine = i + 3 < relevantLines.length ? relevantLines[i + 3] : '';

    let currentYearVal = currentYearLine;
    let name = '';

    const prevLine = i > 0 ? relevantLines[i - 1] : '';
    if (prevLine && !/^\d/.test(prevLine) && !/^total/i.test(prevLine) && !/^current|^fixed|^intangible/i.test(prevLine)) {
      name = prevLine;
    }

    const prevYearIsNumeric = /^[-\d,(]+$/.test(prevYearLine) && prevYearLine.length > 0;
    const nextNextIsNumeric = /^[-\d,(]+$/.test(nextNextLine) && nextNextLine.length > 0;

    if (prevYearIsNumeric && !nextNextIsNumeric) {
      currentYearVal = currentYearLine;
    }

    const amount = parseCurrency(currentYearVal);
    if (amount === 0) continue;

    accounts.push({
      gifi,
      name: name || `GIFI ${gifi}`,
      amount
    });
  }

  let totalAssets = 0;
  let totalLiabilitiesEquity = 0;

  for (const a of accounts) {
    if ([1001, 1774, 1740].includes(a.gifi)) totalAssets += Math.max(0, a.amount);
    if ([1775, 1741].includes(a.gifi)) totalAssets += Math.min(0, a.amount);
    if ([2620, 2680, 3500, 3849].includes(a.gifi)) totalLiabilitiesEquity += Math.max(0, a.amount);
    if (a.gifi === 1001 && a.amount < 0) totalLiabilitiesEquity += Math.abs(a.amount);
  }

  const checksumOk = Math.abs(totalAssets - totalLiabilitiesEquity) < 1;

  const result = {
    source: path.basename(inputPath),
    fiscal_year_end: '2025-03-31',
    accounts,
    total_assets: parseFloat(totalAssets.toFixed(2)),
    total_liabilities_equity: parseFloat(totalLiabilitiesEquity.toFixed(2)),
    checksum_ok: checksumOk
  };

  return result;
}

function main() {
  const args = process.argv.slice(2);
  let inputPath = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--input') inputPath = args[++i];
  }
  if (!inputPath) {
    console.error('Usage: node extract-t2-s100.mjs --input <path-to-extraction.md>');
    process.exit(1);
  }
  const result = extractT2S100(inputPath);
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && import.meta.url === `file://${process.argv[1]}`) {
  main().catch(e => { console.error(e.message); process.exit(1); });
}
