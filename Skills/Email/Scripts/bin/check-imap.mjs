import os from 'os';
import { checkMailbox, downloadAttachments, listMailboxes, downloadUids } from '../lib/imap.mjs';

function mimeDecode(str) {
  if (!str || !str.includes('=?')) return str;
  return str.replace(/=\?([^?]+)\?(B|Q)\?([^?]*)\?=/g, (_, charset, enc, text) => {
    try {
      if (enc === 'B') return Buffer.from(text, 'base64').toString('utf8');
      if (enc === 'Q') return decodeURIComponent(text.replace(/=([0-9A-F]{2})/g, '%$1'));
    } catch { return text; }
  });
}

function parseArgs() {
  const args = {};
  for (let i = 2; i < process.argv.length; i++) {
    const arg = process.argv[i];
    if (arg.startsWith('--')) {
      const eqIdx = arg.indexOf('=');
      if (eqIdx !== -1) {
        args[arg.slice(2, eqIdx)] = arg.slice(eqIdx + 1);
      } else {
        const val = process.argv[i + 1];
        if (val && !val.startsWith('--')) {
          args[arg.slice(2)] = val;
          i++;
        } else {
          args[arg.slice(2)] = true;
        }
      }
    }
  }
  return args;
}

function parseUidRange(rangeStr) {
  if (!rangeStr) return [];
  const parts = rangeStr.split(',').map(s => s.trim());
  const uids = [];
  for (const p of parts) {
    const m = p.match(/^(\d+)(?:-(\d+))?$/);
    if (!m) throw new Error(`Invalid UID range: ${p}`);
    const start = parseInt(m[1]);
    const end = m[2] ? parseInt(m[2]) : start;
    for (let i = start; i <= end; i++) uids.push(i);
  }
  return uids;
}

function buildConfig(args) {
  const host = args.host || process.env.EMAIL_HOST || 'webhosting2049.is.cc';
  const port = parseInt(args.port || process.env.EMAIL_PORT || '993', 10);
  const tls = args.tls !== 'false';
  const user = args.user || process.env.EMAIL_USER || '';
  const password = args.pass || process.env.EMAIL_PASS || '';
  return { host, port, tls, user, password };
}

async function main() {
  const args = parseArgs();
  const action = args._ || (args.mailbox ? 'check' : 'help');
  const config = buildConfig(args);

  if (args.help || args.h) {
    console.log(`
Usage: node bin/check-imap.mjs [options]

Options:
  --user=<email>         IMAP username (or EMAIL_USER env)
  --pass=<password>      IMAP password (or EMAIL_PASS env)
  --host=<host>          IMAP server (default: webhosting2049.is.cc)
  --port=<port>          IMAP port (default: 993)
  --mailbox=<name>       Mailbox to check (default: INBOX)
  --output=<dir>         Download attachments to this directory
  --uid-range=<range>    Download specific UIDs (e.g. "2-25" or "1,3,5-10")
  --all                  Search ALL messages, not just UNSEEN
  --dry-run              Show what would be downloaded without doing it
  --images               Include image attachments (default: true)
  --list-mailboxes       List available mailboxes and exit
  --help                 Show this help
    `.trim());
    return;
  }

  if (args['list-mailboxes']) {
    const boxes = await listMailboxes(config);
    console.log(JSON.stringify(boxes, null, 2));
    return;
  }

  if (!config.user || !config.password) {
    console.error('Error: --user and --pass are required (or set EMAIL_USER/EMAIL_PASS env vars)');
    process.exit(1);
  }

  const mailbox = args.mailbox || 'INBOX';
  const dryRun = !!args['dry-run'];

  console.error(`Connecting to ${config.host}:${config.port} as ${config.user}, mailbox: ${mailbox}${dryRun ? ' (DRY RUN)' : ''}`);

  let messages;
  if (args['uid-range']) {
    const uids = parseUidRange(args['uid-range']);
    console.error(`Fetching ${uids.length} UIDs: ${uids[0]}-${uids[uids.length-1]}`);
    messages = await downloadUids(config, uids, mailbox);
  } else {
    messages = await checkMailbox(config, mailbox, !!args['all']);
  }

  if (messages.length === 0) {
    console.log(JSON.stringify({ checked: mailbox, found: 0, downloaded: 0 }));
    process.exit(0);
  }

  if (dryRun) {
    console.log(JSON.stringify({
      checked: mailbox,
      found: messages.length,
      dryRun: true,
      messages: messages.map(m => ({
        uid: m.uid,
        subject: mimeDecode(m.subject),
        from: m.from,
        date: m.date,
        attachmentCount: m.attachments.length,
      })),
    }));
    return;
  }

  const outputDir = args.output || process.env.EMAIL_OUTPUT_DIR || os.tmpdir();
  const includeImages = args.images !== 'false';
  const results = await downloadAttachments(config, messages.map(m => m.uid), outputDir, includeImages);

  let totalDownloaded = 0;
  for (const r of results) {
    totalDownloaded += (r.files || []).length;
  }

  const summary = {
    checked: mailbox,
    found: messages.length,
    downloaded: totalDownloaded,
    results,
  };

  console.log(JSON.stringify(summary, null, 2));
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
