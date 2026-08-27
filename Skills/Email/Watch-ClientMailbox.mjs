import { watchMailboxes } from './Scripts/lib/imap.mjs';
import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

function loadClientRegistry() {
  const path = join(__dirname, '..', 'Infrastructure', 'clients', 'email-monitor-registry.json');
  if (!existsSync(path)) {
    console.warn('No email-monitor-registry.json found. Run --init or Register-ClientEmailMonitor.ps1 first.');
    return [];
  }
  const raw = readFileSync(path, 'utf8');
  return JSON.parse(raw);
}

function parseArgs() {
  const args = process.argv.slice(2);
  const flags = { dryRun: false, init: false, client: null, mailboxes: [] };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--dry-run') flags.dryRun = true;
    else if (args[i] === '--init') flags.init = true;
    else if (args[i] === '--client') flags.client = args[++i];
    else if (args[i] === '--mailbox') {
      const [user, host, pass, mailbox] = args[++i].split(':');
      flags.mailboxes.push({ key: user, user, host, password: pass, mailbox: mailbox || 'INBOX' });
    }
  }
  return flags;
}

async function main() {
  const flags = parseArgs();
  const stateFile = join(__dirname, '..', 'Tasks', 'Logs', 'email-watch-state.json');

  if (flags.dryRun) {
    console.log('DRY RUN — would watch:');
    if (flags.client) {
      console.log(`  Client: ${flags.client}`);
    } else {
      const registry = loadClientRegistry();
      if (registry.length === 0) {
        console.log('  No registered clients (empty registry).');
      } else {
        for (const entry of registry) {
          process.stdout.write(`  - ${entry.email} (client: ${entry.client})`);
          if (flags.client && entry.client !== flags.client) { console.log(' [skipped]'); continue; }
          console.log(' [active]');
        }
      }
    }
    return { dryRun: true, configuredMailboxes: flags.mailboxes.length };
  }

  let configs;
  if (flags.mailboxes.length > 0) {
    configs = flags.mailboxes;
  } else {
    const registry = loadClientRegistry();
    configs = registry
      .filter(e => !flags.client || e.client === flags.client)
      .map(e => ({
        key: e.email,
        user: e.email,
        password: e.password,
        host: e.host || e.imap_host,
        port: e.port || e.imap_port || 993,
        mailbox: e.mailbox || 'INBOX',
        download_dir: join(__dirname, '..', 'Clients', e.client, 'incoming', String(Date.now())),
      }));
  }

  if (configs.length === 0) {
    console.log('No mailboxes configured. Use --init or Register-ClientEmailMonitor.ps1.');
    return;
  }

  console.log(`Watching ${configs.length} mailbox(es)...`);

  const results = await watchMailboxes(configs, stateFile);
  const errors = results.filter(r => r.error);
  if (errors.length > 0) {
    console.error(`${errors.length} error(s):`);
    for (const e of errors) console.error(`  [${e.mailbox}] ${e.error}`);
  }
  const ok = results.length - errors.length;
  if (ok > 0) console.log(`${ok} mailbox(es) checked successfully.`);

  return { checked: configs.length, errors: errors.length };
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
