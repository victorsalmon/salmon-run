import { listMailboxes, checkMailbox } from '../lib/imap.mjs';

const CONFIG = {
  host: 'webhosting2049.is.cc',
  port: 993,
  tls: true,
};

async function testAccount(label, user, password) {
  console.log(`\n=== Testing: ${label} (${user}) ===`);
  const config = { ...CONFIG, user, password };

  try {
    console.log('  Connecting and listing mailboxes...');
    const boxes = await listMailboxes(config);
    const flatNames = boxes.map(b => b.name);
    console.log(`  Mailboxes found (${flatNames.length}): ${flatNames.join(', ')}`);

    console.log('  Checking INBOX for unseen messages...');
    const messages = await checkMailbox(config, 'INBOX');
    console.log(`  Unseen messages: ${messages.length}`);
    if (messages.length > 0) {
      for (const msg of messages.slice(0, 5)) {
        console.log(`    - [${msg.uid}] Subject: ${msg.subject || '(none)'}`);
        console.log(`      From: ${msg.from || '(unknown)'}`);
        console.log(`      Date: ${msg.date || '(unknown)'}`);
        console.log(`      Attachments: ${msg.attachments.length}`);
        for (const att of msg.attachments) {
          console.log(`        * ${att.filename} (${att.type}, ${att.size} bytes)`);
        }
      }
      if (messages.length > 5) {
        console.log(`    ... and ${messages.length - 5} more`);
      }
    }

    return { label, success: true, mailboxes: flatNames.length, unseen: messages.length };
  } catch (err) {
    console.log(`  FAILED: ${err.message}`);
    return { label, success: false, error: err.message };
  }
}

async function main() {
  console.log('IMAP Connectivity Test');
  console.log(`Host: ${CONFIG.host}:${CONFIG.port} (TLS: ${CONFIG.tls})`);
  console.log('='.repeat(60));

  const intersiteUser = process.env.RECEIPTS_INTERSITE_EMAIL || process.argv[2];
  const intersitePass = process.env.RECEIPTS_INTERSITE_PASS || process.argv[3];
  const rentalsUser = process.env.RECEIPTS_RENTALS_EMAIL || process.argv[4];
  const rentalsPass = process.env.RECEIPTS_RENTALS_PASS || process.argv[5];

  const results = [];

  if (intersiteUser && intersitePass) {
    results.push(await testAccount('Intersite Consulting', intersiteUser, intersitePass));
  } else {
    console.log('\n=== Skipping Intersite: RECEIPTS_INTERSITE_EMAIL/PASS not set ===');
  }

  if (rentalsUser && rentalsPass) {
    results.push(await testAccount('Room Rentals', rentalsUser, rentalsPass));
  } else {
    console.log('\n=== Skipping Room Rentals: RECEIPTS_RENTALS_EMAIL/PASS not set ===');
  }

  console.log('\n' + '='.repeat(60));
  console.log('Summary:');
  let allPassed = true;
  for (const r of results) {
    const icon = r.success ? 'PASS' : 'FAIL';
    if (!r.success) allPassed = false;
    console.log(`  [${icon}] ${r.label}${r.success ? ` — ${r.unseen} unseen, ${r.mailboxes} mailboxes` : ` — ${r.error}`}`);
  }
  console.log(`\nOverall: ${allPassed ? 'ALL PASS' : 'SOME FAILED'}`);
  process.exit(allPassed ? 0 : 1);
}

main();
