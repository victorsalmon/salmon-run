import Imap from 'imap';
import { writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

function buildConnection(config) {
  return new Imap({
    user: config.user, password: config.password,
    host: config.host || 'webhosting2049.is.cc', port: config.port || 993,
    tls: true, tlsOptions: { rejectUnauthorized: true },
    connTimeout: 30000, authTimeout: 10000,
  });
}

function connectAsync(imap) { return new Promise((r,j) => { imap.once('ready',r); imap.once('error',j); imap.connect(); }); }
function openBoxAsync(imap, mb) { return new Promise((r,j) => { imap.openBox(mb||'INBOX', false, (e,b) => e?j(e):r(b)); }); }
function endAsync(imap) { return new Promise(r => { imap.once('end',r); imap.end(); }); }

async function fetchFullBody(imap, uid) {
  return new Promise((resolve, reject) => {
    const parts = {};
    const f = imap.fetch(uid, { bodies: ['HEADER.FIELDS (SUBJECT FROM DATE)', 'TEXT'] });
    f.on('message', (msg) => {
      msg.on('body', (stream, info) => {
        let buf = '';
        stream.on('data', c => buf += c.toString('utf8'));
        stream.on('end', () => { parts[info.which || 'TEXT'] = buf; });
      });
    });
    f.once('error', reject);
    f.once('end', () => resolve(parts));
  });
}

function mimeDecode(str) {
  if (!str || !str.includes('=?')) return str;
  return str.replace(/=\?([^?]+)\?(B|Q)\?([^?]*)\?=/g, (_, charset, enc, text) => {
    try { if (enc === 'B') return Buffer.from(text, 'base64').toString('utf8'); } catch {}
    try { if (enc === 'Q') return decodeURIComponent(text.replace(/=([0-9A-F]{2})/g, '%$1')); } catch {}
    return text;
  });
}

function extractBody(text) {
  if (!text) return '';
  const lines = text.split('\n');
  let inBody = false;
  const bodyLines = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!inBody) {
      if (trimmed === '' || trimmed.startsWith('Content-Type:') || trimmed.startsWith('Content-Transfer-Encoding:') ||
          trimmed.startsWith('MIME-Version:') || trimmed.startsWith('boundary=') || trimmed.startsWith('--') ||
          trimmed.startsWith('From:') || trimmed.startsWith('Date:') || trimmed.startsWith('Subject:') ||
          trimmed.startsWith('To:') || trimmed.startsWith('In-Reply-To:') || trimmed.startsWith('References:') ||
          trimmed.startsWith('Message-ID:') || trimmed.startsWith('Content-Language:') || trimmed.startsWith('Thread-')) {
        continue;
      }
      inBody = true;
    }
    if (trimmed.startsWith('--')) continue;
    if (trimmed.startsWith('Content-Type:') || trimmed.startsWith('Content-Transfer-Encoding:')) continue;
    bodyLines.push(line);
  }
  return bodyLines.join('\n').trim();
}

function extractAmount(text) {
  // Look for patterns like "$36.00", "$89.97", "Total amount: $89.97"
  const patterns = [
    /total[:\s]*\$?(\d+\.?\d*)/i,
    /amount[:\s]*\$?(\d+\.?\d*)/i,
    /\$(\d+\.\d{2})/,
  ];
  for (const p of patterns) {
    const m = text.match(p);
    if (m) return m[1];
  }
  return 'unknown';
}

function extractAccountNumber(text) {
  const m = text.match(/(\d{9,10})/);
  return m ? m[1] : 'unknown';
}

function extractBillDate(subject) {
  // Subject: "Your BC Hydro bill is ready Jan 22, 2026"
  const m = subject.match(/(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},\s*\d{4}/i);
  if (m) {
    const d = new Date(m[0]);
    return d.toISOString().split('T')[0];
  }
  return 'unknown';
}

async function main() {
  const user = process.env.EMAIL_USER;
  const pass = process.env.EMAIL_PASS;
  if (!user || !pass) { console.error('EMAIL_USER and EMAIL_PASS required'); process.exit(1); }

  const uids = [20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37];
  const config = { user, password: pass };

  const imap = buildConnection(config);
  await connectAsync(imap);
  await openBoxAsync(imap, 'INBOX');

  const outDir = 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\bc-hydro-raw';
  mkdirSync(outDir, { recursive: true });

  const results = [];

  for (const uid of uids) {
    const parts = await fetchFullBody(imap, uid);
    const header = parts['HEADER.FIELDS (SUBJECT FROM DATE)'] || '';
    const text = parts['TEXT'] || '';

    const subject = mimeDecode((header.match(/^Subject:\s*(.+)$/im)||[])[1] || `bc-hydro-uid${uid}`);
    const bodyText = extractBody(text);
    const amount = extractAmount(bodyText);
    const account = extractAccountNumber(bodyText);
    const billDate = extractBillDate(subject);

    results.push({ uid, subject, amount, account, billDate });

    const safeSubject = subject.replace(/[<>:"/\\|?*]/g, '_').trim();
    const safeName = `${safeSubject}_UID${uid}`.replace(/[^a-zA-Z0-9._-]/g, '_').replace(/_+/g, '_').slice(0, 100);

    const md = `# BC Hydro Bill — CA$${amount}

**UID**: ${uid}
**Subject**: ${subject}
**Source**: ${mimeDecode((header.match(/^From:\s*(.+)$/im)||[])[1] || '')}
**Date**: ${(header.match(/^Date:\s*(.+)$/im)||[])[1] || ''}
**Bill Date**: ${billDate}
**Amount**: CA$${amount}
**Account**: ${account}

---

${bodyText || '(empty body)'}
`;

    writeFileSync(join(outDir, `${safeName}.md`), md, 'utf8');
    console.log(`UID ${uid}: CA$${amount} | ${billDate} | acct ${account} | ${subject.slice(0, 60)}`);
  }

  await endAsync(imap);

  console.log('\n--- Summary ---');
  for (const r of results) {
    console.log(`UID${r.uid}: $${r.amount} | bill: ${r.billDate} | acct: ${r.account}`);
  }
}

main().catch(e => { console.error(e); process.exit(1); });
