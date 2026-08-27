import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync, statSync } from 'fs';
import { join, parse } from 'path';
import { createHash } from 'crypto';

function fileHash(filePath) {
  try {
    const data = readFileSync(filePath);
    return createHash('sha256').update(data).digest('hex').substring(0, 16);
  } catch { return null; }
}

export function buildManifest(receiptsDir, entity, sidecarResults) {
  const yearDirs = {};
  for (const r of sidecarResults) {
    if (r.error) continue;
    const year = r.date ? r.date.substring(0, 4) : 'unknown';
    if (!yearDirs[year]) yearDirs[year] = [];
    yearDirs[year].push(r);
  }

  const manifests = [];
  for (const [year, receipts] of Object.entries(yearDirs)) {
    const yearDir = join(receiptsDir, `${year} Receipts`);
    mkdirSync(yearDir, { recursive: true });

    const manifestPath = join(yearDir, 'manifest.csv');
    const existingEntries = [];
    if (existsSync(manifestPath)) {
      try {
        const lines = readFileSync(manifestPath, 'utf8').trim().split('\n');
        for (let i = 1; i < lines.length; i++) {
          const parts = lines[i].split(',');
          if (parts.length >= 5) existingEntries.push(parts[0]);
        }
      } catch {}
    }

    const newLines = [];
    for (const r of receipts) {
      const base = join(yearDir, parse(r.file).base);
      try {
        const src = r.file;
        const dst = base;
        if (src !== dst) {
          try {
            const data = readFileSync(src);
            writeFileSync(dst, data);
          } catch {}
        }
      } catch {}
    }

    const allReceiptFiles = readdirSync(yearDir).filter(f => f.endsWith('.pdf'));

    const header = 'filename,original_filename,date,amount,vendor,hash,status';
    const rows = [];
    const seen = new Set(existingEntries);
    for (const f of allReceiptFiles) {
      const fp = join(yearDir, f);
      const h = fileHash(fp);
      const namePart = f.replace(/\.pdf$/, '');
      const parts = namePart.split(' - ');
      const date = parts.length >= 1 ? parts[0] : '';
      const amount = parts.length >= 2 ? parts[1].replace(/^\$/, '') : '';
      const vendor = parts.length >= 3 ? parts.slice(2).join(' - ') : '';
      if (seen.has(f)) continue;
      rows.push(`${f},,${date},${amount},"${vendor}",${h},downloaded`);
      seen.add(f);
    }

    if (rows.length > 0) {
      const existing = existsSync(manifestPath) ? readFileSync(manifestPath, 'utf8').trim() + '\n' : header + '\n';
      writeFileSync(manifestPath, existing + rows.join('\n') + '\n', 'utf8');
    }

    manifests.push({ year, path: manifestPath, newEntries: rows.length, totalFiles: allReceiptFiles.length });
  }

  return manifests;
}
