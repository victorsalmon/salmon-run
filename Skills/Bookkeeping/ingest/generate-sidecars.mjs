import { readFileSync, writeFileSync, renameSync, readdirSync, existsSync, mkdirSync } from 'fs';
import { join, parse } from 'path';
import { execFileSync } from 'child_process';

const VALID_YEARS = [2024, 2025, 2026, 2027];

function parseDate(text) {
  const patterns = [
    /(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})/,
    /(\d{1,2})[-\/](\d{1,2})[-\/](\d{4})/,
    /([A-Z][a-z]+)\s+(\d{1,2}),?\s*(\d{4})/,
    /(\d{1,2})\s+([A-Z][a-z]+)\s+(\d{4})/,
  ];
  for (const p of patterns) {
    const m = text.match(p);
    if (!m) continue;
    if (p === patterns[0]) {
      const y = parseInt(m[1]), mo = parseInt(m[2]), d = parseInt(m[3]);
      if (VALID_YEARS.includes(y)) return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    } else if (p === patterns[1]) {
      const mo = parseInt(m[1]), d = parseInt(m[2]), y = parseInt(m[3]);
      if (VALID_YEARS.includes(y)) return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    } else if (p === patterns[2] || p === patterns[3]) {
      const monthMap = { jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12 };
      let moStr = m[1].substring(0,3).toLowerCase(), d, y;
      if (p === patterns[2]) { d = parseInt(m[2]); y = parseInt(m[3]); }
      else { d = parseInt(m[1]); moStr = m[2].substring(0,3).toLowerCase(); y = parseInt(m[3]); }
      const mo = monthMap[moStr];
      if (mo && VALID_YEARS.includes(y)) return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    }
  }
  return null;
}

function parseAmount(text) {
  const m = text.match(/(?:\$|CAD|USD)\s*([0-9,]+(?:\.[0-9]{2})?)/i);
  if (m) return parseFloat(m[1].replace(/,/g, ''));
  const m2 = text.match(/(?:total|amount|due|charged)\s*:?\s*\$?\s*([0-9,]+(?:\.[0-9]{2})?)/i);
  if (m2) return parseFloat(m2[1].replace(/,/g, ''));
  return null;
}

function parseVendor(text, subject) {
  const lines = text.split('\n').filter(l => l.trim()).map(l => l.trim());
  const knownMarkers = [
    /stripe/i, /freedom\s+mobile/i, /shaw/i, /telus/i, /rogers/i,
    /bell/i, /amazon/i, /costco/i, /walmart/i, /homedepot/i, /loblaws/i,
    /metro/i, /fortis/i, /bchydro/i, /icbc/i, /city\s+of/i,
  ];
  for (const marker of knownMarkers) {
    if (text.match(marker)) return text.match(marker)[0].trim();
  }
  if (subject) {
    const subjVendor = subject.match(/from\s+(.+?)(?:\s+receipt|\s+invoice|\s*$)/i);
    if (subjVendor) return subjVendor[1].trim();
  }
  for (const line of lines.slice(0, 10)) {
    if (line.includes('Inc.') || line.includes('Ltd.') || line.includes('Corp.') || line.includes('LLC')) {
      return line.replace(/[^a-zA-Z0-9 .]/g, '').trim().substring(0, 60);
    }
  }
  return 'Unknown Vendor';
}

function extractTextViaPython(pdfPath) {
  try {
    const result = execFileSync('pdftotext', ['-layout', pdfPath, '-'], { encoding: 'utf8', timeout: 30000 });
    if (result && result.trim()) return result;
  } catch {}
  try {
    const result = execFileSync('python3', ['-c', `
import sys
try:
    import pdfplumber
    with pdfplumber.open("${pdfPath.replace(/\\/g, '/')}") as pdf:
        for p in pdf.pages:
            t = p.extract_text() or ''
            sys.stdout.write(t + '\\n')
except:
    try:
        from pdfminer.high_level import extract_text
        sys.stdout.write(extract_text("${pdfPath.replace(/\\/g, '/')}"))
    except:
        sys.exit(1)
`], { encoding: 'utf8', timeout: 60000 });
    if (result && result.trim()) return result;
  } catch {}
  return null;
}

function generateSidecar(pdfPath) {
  const parsed = parse(pdfPath);
  const baseName = parsed.name;

  const text = extractTextViaPython(pdfPath);
  if (!text) {
    return { file: pdfPath, error: 'could not extract text', sidecar: null };
  }

  const date = parseDate(text);
  const amount = parseAmount(text);
  const vendor = parseVendor(text, baseName);

  const shortBase = date
    ? `${date} - ${amount ? '$' + amount.toFixed(2) : 'NOAMOUNT'} - ${vendor}`
    : `${baseName}`;

  const dir = parsed.dir || '.';
  const sidecarPath = join(dir, shortBase + '.csv');
  const csvLines = [
    'invoice_number,vendor,date_issued,amount,currency,description_short',
    `${baseName},"${vendor}",${date || ''},${amount || ''},CAD,"Auto-extracted from ${baseName}"`,
  ];
  writeFileSync(sidecarPath, csvLines.join('\n') + '\n', 'utf8');

  const mdPath = join(dir, shortBase + '.md');
  writeFileSync(mdPath, `# ${vendor}\n\n> Source: ${baseName}\n> Extracted: ${new Date().toISOString().split('T')[0]}\n\n${text}\n`, 'utf8');

  const newPdfPath = join(dir, shortBase + '.pdf');
  if (baseName !== shortBase) {
    try { renameSync(pdfPath, newPdfPath); } catch {}
  }

  return {
    file: newPdfPath,
    date,
    amount,
    vendor,
    sidecar: shortBase + '.csv',
    md: shortBase + '.md',
  };
}

export function getYearBucket(dateStr) {
  if (!dateStr) return null;
  const m = dateStr.match(/^(\d{4})/);
  return m ? m[1] : null;
}

export function processDirectory(dir) {
  if (!existsSync(dir)) return { processed: 0, results: [] };
  const files = readdirSync(dir).filter(f => f.endsWith('.pdf'));
  const results = [];
  for (const file of files) {
    const filePath = join(dir, file);
    const result = generateSidecar(filePath);
    results.push(result);
  }
  return { processed: results.length, results };
}

export { generateSidecar, parseDate, parseAmount, parseVendor };
