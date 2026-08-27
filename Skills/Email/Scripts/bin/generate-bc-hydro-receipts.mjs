import { readFileSync, writeFileSync, copyFileSync, existsSync, mkdirSync, readdirSync } from 'fs';
import { join } from 'path';

const rawDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\bc-hydro-raw';
const ingestDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\ingest';
mkdirSync(ingestDir, { recursive: true });

// Map: bill-file-marker -> { manifest_date, amount, account }
const ENTRIES = [
  // MLM property ($36, TD-MLM-6467010, acct 9934259658)
  { marker: 'UID26', bankDate: '2026-01-07', amount: '36.00', account: 'TD-MLM-6467010', billDate: 'Jan 2, 2026' },
  { marker: 'UID20', bankDate: '2026-02-09', amount: '36.00', account: 'TD-MLM-6467010', billDate: 'Feb 2, 2026' },
  { marker: 'UID37', bankDate: '2026-03-10', amount: '36.00', account: 'TD-MLM-6467010', billDate: 'Mar 4, 2026' },
  { marker: 'UID34', bankDate: '2026-04-08', amount: '36.00', account: 'TD-MLM-6467010', billDate: 'Apr 1, 2026' },
  { marker: 'UID30', bankDate: '2026-05-11', amount: '36.00', account: 'TD-MLM-6467010', billDate: 'May 4, 2026' },
  { marker: 'UID27', bankDate: '2026-06-09', amount: '36.00', account: 'TD-MLM-6467010', billDate: 'Jun 3, 2026' },
  // FRA property ($77-89, RBC-FRA-5172549)
  { marker: 'UID22', bankDate: '2026-01-30', amount: '89.00', account: 'RBC-FRA-5172549', billDate: 'Jan 22, 2026' },
  { marker: 'UID21', bankDate: '2026-03-03', amount: '89.00', account: 'RBC-FRA-5172549', billDate: 'Feb 23, 2026' },
  { marker: 'UID36', bankDate: '2026-04-01', amount: '89.00', account: 'RBC-FRA-5172549', billDate: 'Mar 24, 2026' },
  { marker: 'UID32', bankDate: '2026-05-05', amount: '77.00', account: 'RBC-FRA-5172549', billDate: 'Apr 23, 2026' },
  { marker: 'UID28', bankDate: '2026-06-02', amount: '89.00', account: 'RBC-FRA-5172549', billDate: 'May 25, 2026' },
];

// Also handle the "BILL PAYMENT" entries from TMH (Scotia) that were forwarded
// These were marked NO_RECEIPT_NEEDED but now we have receipts for them
const EXTRA = [
  { marker: 'UID23', bankDate: '2026-01-13', amount: '153.44', account: 'SCOTIA-TMH', billDate: 'Jan 5, 2026' },
  { marker: 'UID25', bankDate: '2026-02-11', amount: '169.89', account: 'SCOTIA-TMH', billDate: 'Feb 3, 2026' },
  { marker: 'UID35', bankDate: '2026-03-13', amount: '182.61', account: 'SCOTIA-TMH', billDate: 'Mar 5, 2026' },
  { marker: 'UID33', bankDate: '2026-04-10', amount: '175.86', account: 'SCOTIA-TMH', billDate: 'Apr 2, 2026' },
  { marker: 'UID29', bankDate: '2026-05-05', amount: '102.33', account: 'SCOTIA-TMH', billDate: 'May 5, 2026' },
  // Skip UID24 ($254.08 Jun 4) and UID31 (Peak Saver recap)
];

function generateHTML(amount, billDate, bankDate, account, acctNum) {
  const formattedDate = new Date(bankDate).toLocaleDateString('en-CA', { year: 'numeric', month: 'long', day: 'numeric' });
  return `<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; padding: 40px; max-width: 700px; margin: 0 auto; color: #1c1c1c; }
  .receipt { border: 1px solid #ddd; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); }
  h1 { font-size: 22px; color: #0047AB; margin: 0 0 8px 0; }
  .logo { color: #0047AB; font-size: 24px; font-weight: bold; margin-bottom: 4px; }
  .meta { color: #65676b; font-size: 13px; margin-bottom: 24px; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 10px 0; border-bottom: 1px solid #e5e5e5; font-size: 14px; }
  td:last-child { text-align: right; font-weight: 600; }
  .total td { border-bottom: none; padding-top: 16px; font-size: 16px; }
  .total td:last-child { font-size: 18px; color: #050505; }
  .label { color: #65676b; }
</style></head>
<body>
<div class="receipt">
  <div class="logo">⚡ BC Hydro</div>
  <p style="color:#65676b;font-size:11px;margin:0 0 16px 0">Bill notification — forwarded from email</p>
  <h1>BC Hydro Bill</h1>
  <div class="meta">Account: ${acctNum}</div>
  <table>
    <tr><td class="label">Amount billed</td><td>CA$${amount}</td></tr>
    <tr><td class="label">Bill date</td><td>${billDate}</td></tr>
    <tr><td class="label">Transaction date</td><td>${formattedDate}</td></tr>
    <tr><td class="label">Account number</td><td>${acctNum}</td></tr>
    <tr><td class="label">Bank account</td><td>${account}</td></tr>
    <tr class="total"><td>Total</td><td>CA$${amount}</td></tr>
  </table>
  <p style="color:#65676b;font-size:11px;margin-top:24px">BC Hydro — Power smart</p>
</div>
</body></html>`;
}

function extractAcctNum(bodyText) {
  const m = bodyText.match(/(?:Account|acct)[:\s#]*(\d{6,12})/i);
  if (m) return m[1];
  // Try raw number
  const m2 = bodyText.match(/^(\d{9,10})/m);
  if (m2) return m2[1];
  // From the raw dump we saw numbers like 9934259658
  const m3 = bodyText.match(/(\d{9,11})/);
  if (m3) return m3[1];
  return 'unknown';
}

async function main() {
  const rawFiles = readdirSync(rawDir);

  for (const entry of [...ENTRIES, ...EXTRA]) {
    const rawFile = rawFiles.find(f => f.includes(entry.marker));
    if (!rawFile) { console.error(`Missing raw file for ${entry.marker}`); continue; }

    const rawContent = readFileSync(join(rawDir, rawFile), 'utf8');
    const bodyStart = rawContent.indexOf('---\n\n');
    const bodyText = bodyStart !== -1 ? rawContent.slice(bodyStart + 4) : rawContent;
    // Remove the trailing HTML content (after Content-Type: text/html)
    const textOnlyBody = bodyText.replace(/Content-Type: text\/html[\s\S]*$/i, '').trim();

    const acctNum = extractAcctNum(textOnlyBody);
    const baseName = `${entry.bankDate} - ${entry.amount} - BC Hydro`;
    const vendor = 'BC Hydro';

    // 1. Write .md
    const cleanMd = `# BC Hydro Bill

**Account**: ${acctNum}
**Amount**: CA$${entry.amount}
**Bill Date**: ${entry.billDate}
**Transaction Date**: ${entry.bankDate}
**Bank Account**: ${entry.account}
**Source**: Email forwarded to receipts-room-rentals@clocklobster.com

---

${textOnlyBody}
`;
    writeFileSync(join(ingestDir, `${baseName}.md`), cleanMd, 'utf8');
    console.log(`Wrote ${baseName}.md`);

    // 2. Write .csv sidecar
    const desc = `BC Hydro bill ${entry.billDate}`;
    const sidecar = `"filename","date","amount","vendor","description","account","reference"
"${baseName}.jpg","${entry.bankDate}","${entry.amount}","${vendor}","${desc}","${entry.account}","${acctNum}"
"${baseName}.pdf","${entry.bankDate}","${entry.amount}","${vendor}","${desc}","${entry.account}","${acctNum}"
`;
    writeFileSync(join(ingestDir, `${baseName}.csv`), sidecar, 'utf8');
    console.log(`Wrote ${baseName}.csv`);

    // 3. Write .html for screenshot
    const html = generateHTML(entry.amount, entry.billDate, entry.bankDate, entry.account, acctNum);
    writeFileSync(join(ingestDir, `${baseName}.html`), html, 'utf8');
    console.log(`Wrote ${baseName}.html`);
  }

  console.log(`\nGenerated ${ENTRIES.length} receipt entries + ${EXTRA.length} extra entries. Now need to screenshot HTML to JPG via Browserless.`);
}

main().catch(e => { console.error(e); process.exit(1); });
