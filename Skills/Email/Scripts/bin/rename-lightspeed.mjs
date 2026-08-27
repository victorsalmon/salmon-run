import { readFileSync, writeFileSync, renameSync, copyFileSync, mkdirSync, existsSync, readdirSync } from 'fs';
import { join } from 'path';

const srcDir = 'C:\\Users\\Victor\\AppData\\Local\\Temp\\lightspeed-ingest';
const ingestDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\ingest';
mkdirSync(ingestDir, { recursive: true });

// Map converter output names to canonical bank-transaction-date names
// Format: { "converter_vendor_string": { date, amount, pdfUid } }
const map = {
  'InternetLightspeed Jan15th,2026 1888378 76837': { date: '2026-01-02', amount: '83.95', pdfUid: '10' },
  'InternetLightspeed Feb15th,2026 1909480 76837': { date: '2026-02-02', amount: '83.95', pdfUid: '17' },
  'InternetLightspeed Mar15th,2026 1933023 76837': { date: '2026-03-02', amount: '83.95', pdfUid: '15' },
  'InternetLightspeed Apr16th,2026 1968236 76837': { date: '2026-04-01', amount: '83.95', pdfUid: '12' },
  'InternetLightspeed May15th,2026 1983205 76837': { date: '2026-05-01', amount: '83.95', pdfUid: '11' },
  'InternetLightspeed Jan1st,2026 1874056 48927': { date: '2026-01-15', amount: '55.95', pdfUid: '9' },
  'InternetLightspeed Feb1st,2026 1896718 48927': { date: '2026-02-01', amount: '55.95', pdfUid: '18' },
  'InternetLightspeed Mar1st,2026 1926270 48927': { date: '2026-03-01', amount: '55.95', pdfUid: '16' },
  'InternetLightspeed Apr1st,2026 1952776 48927': { date: '2026-04-01', amount: '55.95', pdfUid: '13' },
  'InternetLightspeed May1st,2026 1976721 48927': { date: '2026-05-01', amount: '55.95', pdfUid: '14' },
  'InternetLightspeed Jun1st,2026 2003237 48927': { date: '2026-06-01', amount: '55.95', pdfUid: '19' },
};

function findFile(dir, pattern) {
  const files = readdirSync(dir);
  const match = files.find(f => f.includes(pattern));
  return match ? join(dir, match) : null;
}

for (const [vendor, info] of Object.entries(map)) {
  const base = `${info.date} - ${info.amount} - Internet Lightspeed`;

  // Find and copy .md and .csv from converter output
  for (const ext of ['csv', 'md']) {
    const src = findFile(srcDir, vendor.replace(/[/\\?%*:|"<> ]/g, '_'));
    if (!src) {
      // Try matching by vendor name in filename
      const vendorSlug = vendor.replace(/[^a-zA-Z0-9]/g, '_');
      const files = readdirSync(srcDir);
      const match = files.find(f => f.endsWith(`.${ext}`) && f.includes(vendorSlug));
      if (match) {
        copyFileSync(join(srcDir, match), join(ingestDir, `${base}.${ext}`));
        console.log(`Copied ${base}.${ext}`);
      }
    }
  }

  // Try to find and copy the original PDF by UID
  const pdfFile = findFile(srcDir, `_${info.pdfUid}_`);
  if (pdfFile) {
    copyFileSync(pdfFile, join(ingestDir, `${base}.pdf`));
    console.log(`Copied ${base}.pdf`);
  }
}

console.log('\nAll done. Verifying...');
// Check what ended up in ingest
const ingestFiles = readdirSync(ingestDir).filter(f => f.includes('Internet'));
console.log(`Files in ingest: ${ingestFiles.length}`);
ingestFiles.sort().forEach(f => console.log(`  ${f}`));
