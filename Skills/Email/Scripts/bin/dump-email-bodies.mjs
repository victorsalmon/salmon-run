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
        stream.on('end', () => {
          const key = info.which || 'TEXT';
          parts[key] = buf;
        });
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
  let bodyStart = false;
  let bodyLines = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!bodyStart) {
      if (trimmed === '' || trimmed.startsWith('Content-Type:') || trimmed.startsWith('Content-Transfer-Encoding:') ||
          trimmed.startsWith('MIME-Version:') || trimmed.startsWith('boundary=') || trimmed.startsWith('--')) {
        continue;
      }
      bodyStart = true;
    }
    if (trimmed.startsWith('--')) continue;
    bodyLines.push(line);
  }
  return bodyLines.join('').trim();
}

async function main() {
  const user = process.env.EMAIL_USER;
  const pass = process.env.EMAIL_PASS;
  if (!user || !pass) { console.error('EMAIL_USER and EMAIL_PASS required'); process.exit(1); }

  const uids = [3,4,5,6,7,8];
  const config = { user, password: pass };

  const imap = buildConnection(config);
  await connectAsync(imap);
  await openBoxAsync(imap, 'INBOX');

  const outDir = process.argv[2] || 'C:\\Users\\Victor\\intersite-docs\\Taxes and Bookkeeping\\room-rentals\\2026 Receipts\\meta-ads';
  mkdirSync(outDir, { recursive: true });

  for (const uid of uids) {
    const parts = await fetchFullBody(imap, uid);
    const header = parts['HEADER.FIELDS (SUBJECT FROM DATE)'] || '';
    const text = parts['TEXT'] || '';

    const subject = mimeDecode((header.match(/^Subject:\s*(.+)$/im)||[])[1] || `meta-ads-uid${uid}`).replace(/[<>:"/\\|?*]/g, '_').trim();
    const bodyText = extractBody(text);

    const amountMatch = bodyText.match(/CA\$(\d+\.\d+)/);
    const amount = amountMatch ? amountMatch[1] : 'unknown';
    const dateRangeMatch = bodyText.match(/Date range\s+([\d]+\s\w+\s[\d]{4})/);
    const dateRange = dateRangeMatch ? dateRangeMatch[1] : 'unknown';
    const refNumMatch = bodyText.match(/Reference number\s+([A-Z0-9]+)/);
    const refNum = refNumMatch ? refNumMatch[1] : 'unknown';

    const md = `# Meta Ads Receipt — CA$${amount}\n\n**UID**: ${uid}\n**Source**: ${mimeDecode((header.match(/^From:\s*(.+)$/im)||[])[1] || '')}\n**Date**: ${(header.match(/^Date:\s*(.+)$/im)||[])[1] || ''}\n**Amount**: CA$${amount}\n**Date Range**: ${dateRange}\n**Reference**: ${refNum}\n\n---\n\n${bodyText || '(empty body)'}\n`;
    const safeName = `${subject}_UID${uid}`.replace(/[^a-zA-Z0-9._-]/g, '_').replace(/_+/g, '_').slice(0, 80);
    const mdPath = join(outDir, `${safeName}.md`);
    writeFileSync(mdPath, md, 'utf8');
    console.log(`Wrote ${mdPath}`);
  }

  await endAsync(imap);
  console.log('Done');
}

main().catch(e => { console.error(e); process.exit(1); });
