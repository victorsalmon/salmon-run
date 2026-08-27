const fs = require('fs');
const path = require('path');
const { ZohoAuth } = require('./zoho-auth');
const { ZohoContacts } = require('./zoho-contacts');
const { ZohoExpenses } = require('./zoho-expenses');

const STATE_FILE = '.zoho-upload-state.json';
const ENTITIES_FILE = path.join(__dirname, 'zoho-entities.json');

const sleep = ms => new Promise(r => setTimeout(r, ms));

class ZohoUpload {
  constructor({ entities, stateDir, receiptsBase }) {
    this.entities = entities;
    this.stateDir = stateDir || process.cwd();
    this.receiptsBase = receiptsBase || path.join(process.env.USERPROFILE || '~', 'intersite-docs', 'Taxes and Bookkeeping');
    this.auth = null;
    this.contacts = null;
    this.expenses = null;
  }

  async _initAuth() {
    this.auth = await ZohoAuth.ensureAuth();
    this.contacts = new ZohoContacts(this.auth, this.stateDir);
    this.expenses = new ZohoExpenses(this.auth);
  }

  async _loadState(entitySlug) {
    const sp = path.join(this.stateDir, STATE_FILE.replace('.json', '-' + entitySlug + '.json'));
    try {
      const raw = fs.readFileSync(sp, 'utf8');
      const parsed = JSON.parse(raw);
      if (typeof parsed !== 'object' || parsed === null) return { completed: [], failed: [] };
      return parsed;
    } catch { return { completed: [], failed: [] }; }
  }

  async _saveState(entitySlug, state) {
    const sp = path.join(this.stateDir, STATE_FILE.replace('.json', '-' + entitySlug + '.json'));
    fs.mkdirSync(path.dirname(sp), { recursive: true });
    fs.writeFileSync(sp, JSON.stringify(state, null, 2));
  }

  async run(entitySlug, { dryRun = false } = {}) {
    const ent = this.entities[entitySlug];
    if (!ent) throw new Error('Unknown entity: ' + entitySlug + '. Available: ' + Object.keys(this.entities).join(', '));

    await this._initAuth();
    await this.auth.getToken();
    const state = await this._loadState(entitySlug);
    console.log('\n=== ' + ent.displayName + ' ===');

    const receiptsDir = path.join(this.receiptsBase, ent.receiptsDir);
    let manifestPath = path.join(receiptsDir, 'manifest-enriched.csv');
    if (!fs.existsSync(manifestPath)) {
      manifestPath = path.join(receiptsDir, 'manifest.csv');
      if (!fs.existsSync(manifestPath)) throw new Error('No manifest found in ' + receiptsDir);
      console.warn('  Using manifest.csv (not enriched) - no suggested_account_id');
    }

    const csv = fs.readFileSync(manifestPath, 'utf8').replace(/^\uFEFF/, '');
    const lines = csv.trim().split('\n');
    const headers = lines[0].split(',').map(h => h.replace(/^"|"$/g, '').trim());
    const rows = lines.slice(1).filter(l => l.trim()).map(l => {
      const vals = [];
      let current = '', inQuotes = false;
      for (let i = 0; i < l.length; i++) {
        const ch = l[i];
        if (ch === '"') {
          if (inQuotes && i + 1 < l.length && l[i + 1] === '"') { current += '"'; i++; continue; }
          inQuotes = !inQuotes; continue;
        }
        if (ch === ',' && !inQuotes) { vals.push(current.trim()); current = ''; continue; }
        current += ch;
      }
      vals.push(current.trim());
      const obj = {};
      headers.forEach((h, i) => obj[h] = (vals[i] || ''));
      return obj;
    });

    console.log('  ' + rows.length + ' items in manifest');
    let uploaded = 0, skipped = 0, errors = 0;

    for (const row of rows) {
      const filename = row.filename;
      if (state.completed.includes(filename)) { skipped++; continue; }

      const filepath = path.join(receiptsDir, filename);
      const vendor = row.vendor;
      const amount = parseFloat(row.amount);
      const date = row.date;
      const accountId = row.suggested_account_id || (ent.accounts && ent.accounts.mc);
      const paidThroughId = ent.accounts.mc;
      const description = row.notes || (vendor + ' - ' + amount);

      if (!filepath || !amount || !date) {
        console.warn('  SKIP (missing data): ' + filename);
        skipped++;
        continue;
      }

      if (isNaN(amount) || amount <= 0) {
        console.warn('  SKIP (invalid/zero/negative amount): ' + filename);
        skipped++;
        continue;
      }

      console.log('  ' + filename);

      if (dryRun) {
        console.log('    [DRY-RUN] vendor=' + vendor + ' amount=' + amount + ' account=' + accountId);
        uploaded++;
        continue;
      }

      try {
        const vendorId = await this.contacts.ensureContact(ent.orgId, vendor);
        if (!vendorId) console.warn('    [WARN] No vendor contact for ' + vendor);
        const expenseId = await this.expenses.create(ent.orgId, { accountId, paidThroughAccountId: paidThroughId, vendorId, amount, date, description });
        console.log('    Created expense ' + expenseId);

        if (fs.existsSync(filepath)) {
          const ok = await this.expenses.uploadReceipt(ent.orgId, expenseId, filepath);
          console.log('    ' + (ok ? '[OK]' : '[WARN]') + ' Receipt uploaded');
        } else {
          console.warn('    [WARN] File not found: ' + filename);
        }

        state.completed.push(filename);
        this._saveState(entitySlug, state);
        uploaded++;
      } catch (err) {
        console.error('\n  FAILED at ' + filename + ': ' + err.message);
        console.error('  Stopping batch. State saved - fix the issue and re-run to resume.');
        state.failed.push({ filename, error: err.message });
        this._saveState(entitySlug, state);
        errors++;
        break;
      }
    }

    console.log('\n  Done: ' + uploaded + ' uploaded, ' + skipped + ' skipped, ' + errors + ' errors');
    return { uploaded, skipped, errors };
  }
}

async function main() {
  const args = process.argv.slice(2);
  const entity = args[0];
  const dryRun = args.includes('--dry-run');

  if (!entity) {
    console.error('Usage: node zoho-upload.js <entity> [--dry-run]');
    let entitiesList;
    try { entitiesList = JSON.parse(fs.readFileSync(ENTITIES_FILE, 'utf8')); } catch (e) { console.error('  Failed to parse entities file: ' + e.message); process.exit(1); }
    console.error('  Entities: ' + Object.keys(entitiesList).join(', '));
    process.exit(1);
  }

  let entitiesData;
  try { entitiesData = JSON.parse(fs.readFileSync(ENTITIES_FILE, 'utf8')); } catch (e) { console.error('Failed to parse entities file: ' + e.message); process.exit(1); }
  const uploader = new ZohoUpload({
    entities: entitiesData,
    stateDir: process.cwd()
  });

  await uploader.run(entity, { dryRun });
}

if (require.main === module) main().catch(err => { console.error(err); process.exit(1); });

module.exports = { ZohoUpload };

