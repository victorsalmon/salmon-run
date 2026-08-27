import { checkMailbox, downloadAttachments } from '../../Email/Scripts/lib/imap.mjs';

const MAILBOXES = [
  {
    label: 'intersite',
    user: process.env.RECEIPTS_INTERSITE_EMAIL,
    pass: process.env.RECEIPTS_INTERSITE_PASS,
    outputDir: '/data/receipts/intersite',
  },
  {
    label: 'room-rentals',
    user: process.env.RECEIPTS_RENTALS_EMAIL,
    pass: process.env.RECEIPTS_RENTALS_PASS,
    outputDir: '/data/receipts/room-rentals',
  },
];

const HOST = process.env.EMAIL_HOST || 'webhosting2049.is.cc';
const PORT = parseInt(process.env.EMAIL_PORT || '993', 10);

function buildConfig(mbox) {
  return {
    host: HOST,
    port: PORT,
    tls: true,
    user: mbox.user,
    password: mbox.pass,
  };
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

async function main() {
  const args = parseArgs();
  const includeImages = args['include-images'] === true;
  const results = [];
  for (const mbox of MAILBOXES) {
    try {
      const config = buildConfig(mbox);
      console.error(`[${mbox.label}] Connecting to ${HOST}:${PORT}...`);
      const messages = await checkMailbox(config);
      console.error(`[${mbox.label}] ${messages.length} unseen messages`);
      if (messages.length === 0) {
        results.push({ mailbox: mbox.label, found: 0, downloaded: 0 });
        continue;
      }
      const uids = messages.map(m => m.uid);
      const dlResults = await downloadAttachments(config, uids, mbox.outputDir, includeImages);
      let total = 0;
      for (const r of dlResults) {
        total += (r.files || []).length;
      }
      const types = includeImages ? 'PDF(s)/image(s)' : 'PDF(s)';
      console.error(`[${mbox.label}] Downloaded ${total} ${types}`);
      results.push({ mailbox: mbox.label, found: messages.length, downloaded: total, results: dlResults });
    } catch (err) {
      console.error(`[${mbox.label}] Failed: ${err.message}`);
      results.push({ mailbox: mbox.label, error: err.message, found: 0, downloaded: 0 });
    }
  }
  console.log(JSON.stringify({ checked: results.length, mailboxes: results }));
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
