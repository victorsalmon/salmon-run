import PDFDocument from 'pdfkit';
import fs from 'fs';
import path from 'path';

const receipts = [
  { uid: 28, date: '2026-04-07', amount: '34.44', vendor: 'Freedom Mobile', period: 'apr' },
  { uid: 29, date: '2026-05-08', amount: '33.60', vendor: 'Freedom Mobile', period: 'may' },
  { uid: 30, date: '2026-06-07', amount: '33.60', vendor: 'Freedom Mobile', period: 'jun' },
];

const outputDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\intersite-consulting\\2026 Filing\\Receipts\\rbc-6258';

for (const r of receipts) {
  await new Promise((resolve, reject) => {
    const doc = new PDFDocument({ size: 'LETTER', margin: 50 });
    const safeName = `${r.date} - ${r.amount} - ${r.vendor} - Payment Receipt.pdf`.replace(/[:*?"<>|]/g, '_');
    const fpath = path.join(outputDir, safeName);
    const ws = fs.createWriteStream(fpath);
    doc.pipe(ws);

    doc.fontSize(20).text('Freedom Mobile - Payment Receipt', { align: 'center' });
    doc.moveDown();
    doc.fontSize(12);
    doc.text(`Date of Transaction: ${r.date}`);
    doc.text(`Amount: $${r.amount}`);
    doc.text('Payment Method: MasterCard');
    doc.text('Vendor: Freedom Mobile');
    doc.moveDown();
    doc.text('This is a payment receipt forwarded from the receipt mailbox.');
    doc.text(`Original source: receipts-intersite@clocklobster.com (UID ${r.uid})`);
    doc.moveDown();
    doc.text('--- Details ---');
    doc.text('PO Box 365 Stn. Adelaide');
    doc.text('Toronto ON, M5C 2J5');
    doc.text('');
    doc.text('GST/HST# 105532634 RT0002');
    doc.text('Payment Channel: Auto Pay');

    doc.end();
    ws.on('finish', resolve);
    ws.on('error', reject);
  });
  console.log(`Created: ${r.date} Freedom Mobile receipt`);
}
