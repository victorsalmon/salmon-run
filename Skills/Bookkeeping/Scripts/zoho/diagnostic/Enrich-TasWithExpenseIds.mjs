#!/usr/bin/env node
// DEPRECATED — use Sync-TasReceiptStatus.mjs instead.
// Sync-TasReceiptStatus.mjs combines this script's logic (enriching zoho_expense_id)
// with receipt status sync (zoho_has_receipt) in a single idempotent pipeline.
// This file is kept as a deprecation forwarder only.

import { execSync } from 'child_process';
import { fileURLToPath } from 'url';
import path from 'path';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const replacement = path.resolve(__dirname, 'Sync-TasReceiptStatus.mjs');

console.warn('');
console.warn('  ⚠ DEPRECATED: Enrich-TasWithExpenseIds.mjs is superseded.');
console.warn('  → Use Sync-TasReceiptStatus.mjs instead (idempotent, includes receipt status sync).');
console.warn('  → Delegating to: ' + replacement);
console.warn('');

try {
  const args = process.argv.slice(2).map(a => {
    if (a.includes(' ')) return '"' + a + '"';
    return a;
  }).join(' ');
  execSync('node "' + replacement + '" ' + args, { stdio: 'inherit', cwd: __dirname });
} catch (e) {
  process.exit(e.status || 1);
}
