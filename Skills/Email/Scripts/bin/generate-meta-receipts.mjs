import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';

const metaDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\meta-ads';
const ingestDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\ingest';
mkdirSync(ingestDir, { recursive: true });

// Map UIDs to missing-manifest entries
// Missing entries from missing-receipts-manifest.csv:
export const MANIFEST_ENTRIES = {
  // UID -> { manifest_date, manifest_amount, account }
  8: { manifest_date: '2026-01-12', manifest_amount: '80.44', amount: '80.44', dateRange: '27 Dec 2025', ref: '6A75U8ZH32' },
  7: { manifest_date: '2026-01-29', manifest_amount: '172.20', amount: '172.20', dateRange: '8 Jan 2026', ref: 'Y4YGABHJ32' },
  6: { manifest_date: '2026-02-10', manifest_amount: '59.08', amount: '59.08', dateRange: '28 Jan 2026', ref: '7AZKXBVJ32' },
  5: { manifest_date: '2026-02-24', manifest_amount: '172.20', amount: '172.20', dateRange: '9 Feb 2026', ref: 'N6566DVJ32' },
  4: { manifest_date: '2026-03-10', manifest_amount: '33.82', amount: '33.82', dateRange: '22 Feb 2026', ref: 'M3XCREHJ32' },
  3: { manifest_date: '2026-05-11', manifest_amount: '66.30', amount: '66.30', dateRange: '15 Apr 2026', ref: '9SR7RMVH32' },
};

function sanitize(s) {
  return s.replace(/[<>:"/\\|?*]/g, '_').replace(/\s+/g, ' ').trim();
}

function generateReceiptHTML(amount, dateRange, ref, manifestDate) {
  const formattedDate = new Date(manifestDate).toLocaleDateString('en-CA', { year: 'numeric', month: 'long', day: 'numeric' });
  return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 40px; max-width: 700px; margin: 0 auto; color: #1c1c1c; }
  .receipt { border: 1px solid #ddd; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
  h1 { font-size: 22px; color: #050505; margin: 0 0 8px 0; }
  .meta { color: #65676b; font-size: 13px; margin-bottom: 24px; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 10px 0; border-bottom: 1px solid #e5e5e5; font-size: 14px; }
  td:last-child { text-align: right; font-weight: 600; }
  .total td { border-bottom: none; padding-top: 16px; font-size: 16px; }
  .total td:last-child { font-size: 18px; color: #050505; }
  .label { color: #65676b; }
  .header { display: flex; align-items: center; gap: 8px; margin-bottom: 4px; }
  .header img { width: 80px; height: 16px; }
</style></head>
<body>
<div class="receipt">
  <div class="header">
    <svg width="80" height="16" viewBox="0 0 80 16"><rect width="80" height="16" fill="#1877F2" rx="3"/><text x="8" y="12" fill="white" font-size="9" font-weight="bold">Meta</text></svg>
  </div>
  <p style="color:#65676b;font-size:11px;margin:0 0 16px 0">This is not an invoice — receipt for your records</p>
  <h1>Meta Ads Receipt</h1>
  <div class="meta">Account: Victor Salmon (237208838)</div>
  <table>
    <tr><td class="label">Amount billed</td><td>CA$${amount} CAD</td></tr>
    <tr><td class="label">Date range</td><td>${dateRange}</td></tr>
    <tr><td class="label">Transaction date</td><td>${formattedDate}</td></tr>
    <tr><td class="label">Reference number</td><td>${ref}</td></tr>
    <tr><td class="label">Payment method</td><td>Visa .... 4371</td></tr>
    <tr><td class="label">Account</td><td>TD-MLM-6467010</td></tr>
    <tr class="total"><td>Total</td><td>CA$${amount} CAD</td></tr>
  </table>
  <p style="color:#65676b;font-size:11px;margin-top:24px">Meta Platforms Inc. (formerly Facebook, Inc.)</p>
</div>
</body></html>`;
}

async function main() {
  for (const [uidStr, entry] of Object.entries(MANIFEST_ENTRIES)) {
    const uid = parseInt(uidStr);
    const mdFile = join(metaDir, `Fwd_Your_Meta_ads_receipt_account_ID_237208838_UID${uid}.md`);
    if (!existsSync(mdFile)) {
      console.error(`Missing ${mdFile}, skipping`);
      continue;
    }

    const rawBody = readFileSync(mdFile, 'utf8');
    const bodyStart = rawBody.indexOf('---\n\n');
    const bodyText = bodyStart !== -1 ? rawBody.slice(bodyStart + 4) : rawBody;

    const baseName = `${entry.manifest_date} - ${entry.manifest_amount} - Facebook Meta`;

    // 1. Write clean .md
    const cleanMd = `# Meta Ads Receipt

**Account**: Victor Salmon (237208838)
**Amount**: CA$${entry.amount}
**Date Range**: ${entry.dateRange}
**Transaction Date**: ${entry.manifest_date}
**Reference**: ${entry.ref}
**Payment Method**: Visa .... 4371
**Source**: Email forwarded to receipts-room-rentals@clocklobster.com

---

${bodyText.replace(/Content-Type:.*\n?/g, '').replace(/Content-Transfer-Encoding:.*\n?/g, '').trim()}
`;
    writeFileSync(join(ingestDir, `${baseName}.md`), cleanMd, 'utf8');
    console.log(`Wrote ${baseName}.md`);

    // 2. Write .csv sidecar
    const sidecar = `"filename","date","amount","vendor","description","account","reference"
"${baseName}.jpg","${entry.manifest_date}","${entry.manifest_amount}","Facebook Meta","Meta Ads - ${entry.dateRange}","TD-MLM-6467010","${entry.ref}"
`;
    writeFileSync(join(ingestDir, `${baseName}.csv`), sidecar, 'utf8');
    console.log(`Wrote ${baseName}.csv`);

    // 3. Generate HTML for screenshot
    const html = generateReceiptHTML(entry.amount, entry.dateRange, entry.ref, entry.manifest_date);
    writeFileSync(join(ingestDir, `${baseName}.html`), html, 'utf8');
    console.log(`Wrote ${baseName}.html`);
  }

  console.log('\nAll files written. Now need to screenshot HTML files via Browserless.');
}

main().catch(e => { console.error(e); process.exit(1); });
