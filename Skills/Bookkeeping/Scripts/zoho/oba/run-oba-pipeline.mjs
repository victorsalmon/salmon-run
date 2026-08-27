#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import os from 'os';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const { ZohoAuth } = require('../zoho-auth.js');
const { resolveSync, getOrgId } = require('../resolve-zoho-creds.mjs');

const REPO_ROOT = (() => {
  if (process.env.REPO_ROOT) return path.resolve(process.env.REPO_ROOT);
  const { execSync } = require('child_process');
  try { return execSync('git rev-parse --show-toplevel', { encoding: 'utf8', timeout: 3000 }).trim(); }
  catch { return path.resolve(process.env.USERPROFILE || os.homedir(), 'intersite-orchestrator'); }
})();

const CACHE_DIR = path.resolve(REPO_ROOT, '.zoho-cache');

function ensureCacheDir() {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
}

function parseCliArgs() {
  const args = process.argv.slice(2);
  const opts = { org: null, t2Extraction: null, apply: false, outputDir: null };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--org') opts.org = args[++i];
    if (args[i] === '--t2-extraction') opts.t2Extraction = path.resolve(args[++i]);
    if (args[i] === '--apply') opts.apply = true;
    if (args[i] === '--output-dir') opts.outputDir = path.resolve(args[++i]);
  }
  return opts;
}

async function main() {
  const opts = parseCliArgs();
  const startTime = Date.now();

  if (!opts.org) {
    console.error('Usage: node run-oba-pipeline.mjs --org <orgId> --t2-extraction <path> [--apply] [--output-dir <dir>]');
    process.exit(1);
  }

  if (!opts.t2Extraction) {
    console.error('Error: --t2-extraction path is required');
    process.exit(1);
  }

  if (!fs.existsSync(opts.t2Extraction)) {
    console.error(`Error: T2 extraction file not found: ${opts.t2Extraction}`);
    process.exit(1);
  }

  opts.outputDir = opts.outputDir || CACHE_DIR;
  ensureCacheDir();

  console.log('=== OBA Pipeline ===');
  console.log(`Organization: ${opts.org}`);
  console.log(`T2 extraction: ${opts.t2Extraction}`);
  console.log(`Mode: ${opts.apply ? 'APPLY' : 'DRY-RUN'}`);
  console.log(`Cache dir: ${opts.outputDir}`);
  console.log('');

  let token = null;
  try {
    const creds = resolveSync();
    const auth = ZohoAuth.getInstance({
      clientId: creds.ZOHO_BOOKS_ID,
      clientSecret: creds.ZOHO_BOOKS_SECRET,
      refreshToken: creds.ZOHO_BOOKS_REFRESH,
    });
    token = await auth.getToken();
    console.log('✓ Credentials resolved, token obtained');
  } catch (e) {
    console.error(`✗ Failed to resolve credentials: ${e.message}`);
    process.exit(1);
  }
  console.log('');

  console.log('--- Pass 1: Extract T2 S100 ---');
  let extracted;
  try {
    const { extractT2S100 } = await import('./extract-t2-s100.mjs');
    extracted = extractT2S100(opts.t2Extraction);
    const extractedPath = path.join(opts.outputDir, 'extracted-s100.json');
    fs.writeFileSync(extractedPath, JSON.stringify(extracted, null, 2), 'utf8');
    console.log(`  Found ${extracted.accounts.length} GIFI accounts`);
    console.log(`  Checksum: ${extracted.checksum_ok ? '✓ OK' : '✗ MISMATCH'}`);
    console.log(`  Wrote: ${extractedPath}`);
  } catch (e) {
    console.error(`✗ Extraction failed: ${e.message}`);
    process.exit(1);
  }
  console.log('');

  console.log('--- Pass 2: Map GIFI to Zoho ---');
  let mappedResult;
  try {
    const { mapGifiToZoho } = await import('./map-gifi-to-zoho.mjs');
    mappedResult = await mapGifiToZoho(extracted, opts.org, token);
    const mappedPath = path.join(opts.outputDir, 'mapped-accounts.json');
    fs.writeFileSync(mappedPath, JSON.stringify(mappedResult, null, 2), 'utf8');
    console.log(`  Resolved: ${mappedResult.resolved_accounts.length} accounts`);
    console.log(`  Unmatched: ${mappedResult.unmatched_accounts.length}`);
    if (mappedResult.oba_account) {
      console.log(`  OBA account: ${mappedResult.oba_account.zoho_name} (${mappedResult.oba_account.zoho_id})`);
    }
    console.log(`  Wrote: ${mappedPath}`);

    if (mappedResult.unmatched_accounts.length > 0) {
      console.log('\n  Unmatched accounts:');
      for (const u of mappedResult.unmatched_accounts) {
        console.log(`    - GIFI ${u.gifi} (${u.name}): ${u.reason}`);
      }
    }
  } catch (e) {
    console.error(`✗ Mapping failed: ${e.message}`);
    process.exit(1);
  }
  console.log('');

  console.log('--- Pass 3: Fetch Current OBA State ---');
  let currentState;
  try {
    const { fetchCurrentOba } = await import('./fetch-current-oba.mjs');
    currentState = await fetchCurrentOba(opts.org, token);
    const currentPath = path.join(opts.outputDir, 'current-oba-state.json');
    fs.writeFileSync(currentPath, JSON.stringify(currentState, null, 2), 'utf8');
    console.log(`  Bank accounts: ${currentState.bank_accounts.length}`);
    for (const ba of currentState.bank_accounts) {
      console.log(`    ${ba.name}: opening_balance=${ba.opening_balance ?? 'null'}, balance=${ba.balance ?? '?'}`);
    }
    console.log(`  OBA account: ${currentState.oba_account ? currentState.oba_account.name : 'not yet created'}`);
    console.log(`  Wrote: ${currentPath}`);
  } catch (e) {
    console.error(`✗ Fetch failed: ${e.message}`);
    process.exit(1);
  }
  console.log('');

  console.log('--- Pass 4: Diff & Post ---');
  try {
    const { diffAndPost } = await import('./diff-and-post.mjs');
    const result = await diffAndPost({
      mappedState: mappedResult,
      currentState,
      dryRun: !opts.apply,
      orgId: opts.org,
      token,
    });

    if (!opts.apply) {
      console.log('\n✓ Dry-run complete. Review the diff above.');
      console.log('  To apply changes: run with --apply');
    } else {
      console.log('\n✓ Apply complete.');

      if (result.summary.posted_accounts.length > 0) {
        console.log('  Posted bank accounts:');
        for (const p of result.summary.posted_accounts) {
          console.log(`    ✓ ${p.account}: $${p.amount.toFixed(2)}`);
        }
      }
      if (result.summary.skipped_accounts.length > 0) {
        console.log('  Skipped (already matched):');
        for (const s of result.summary.skipped_accounts) {
          console.log(`    - ${s.account}`);
        }
      }
      if (result.summary.errors.length > 0) {
        console.log('  Errors:');
        for (const e of result.summary.errors) {
          console.log(`    ✗ ${e.account}: ${e.error}`);
        }
      }
    }
  } catch (e) {
    console.error(`✗ Diff & Post failed: ${e.message}`);
    process.exit(1);
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\nPipeline complete in ${elapsed}s`);
}

main().catch(e => { console.error(e.message); process.exit(1); });
