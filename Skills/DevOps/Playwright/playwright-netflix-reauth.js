// netflix-reauth.js
//
// Netflix session re-authenticator.
// Opens the persistent Chrome profile to Netflix's Account page
// and waits for the user to complete sign-in if the session expired.
//
// Usage:
//   node netflix-reauth.js [--timeout=600]
//
// Unlike netflix-login.js, this script does NOT require npm init or any
// setup — it reuses the existing ./Profile/ from the downloader.
//
// Use this when netflix-receipt-downloader.js reports "Session expired"
// or redirects to the login page.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const DATA_DIR = process.env.DATA_DIR || path.resolve(__dirname, './Profile');
const timeoutSec = parseInt(
  process.argv.find(a => a.startsWith('--timeout='))?.split('=')[1] ||
  process.env.REAUTH_TIMEOUT || '600', 10
);
const NEXUS_URL = 'https://www.netflix.com/account/membership';

async function main() {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    console.log('Netflix Re-Authenticator');
    console.log('Opens persistent profile, waits for you to sign in.');
    console.log('');
    console.log('Usage: node netflix-reauth.js [--timeout=600]');
    console.log('');
    console.log('Env:');
    console.log('  DATA_DIR       — path to persistent profile (default: ./Profile)');
    console.log('  REAUTH_TIMEOUT — max wait in seconds (default: 600)');
    process.exit(0);
  }

  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });

  console.log('Netflix Re-Authenticator');
  console.log(`  Profile: ${DATA_DIR}`);
  console.log(`  Timeout: ${timeoutSec}s\n`);

  const browser = await chromium.launchPersistentContext(DATA_DIR, {
    headless: false,
    args: ['--disable-blink-features=AutomationControlled']
  });

  const pages = browser.pages();
  const page = pages.length > 0 ? pages[0] : await browser.newPage();

  await page.goto(NEXUS_URL, { timeout: 30000 }).catch(() => {});
  await sleep(5000);

  // Check if already authenticated
  const url = (page.url() || '').toLowerCase();
  const txt = await page.evaluate(() => document.body.innerText.substring(0, 800)).catch(() => '');
  const lower = txt.toLowerCase();

  if ((url.includes('account') || url.includes('membership')) && !url.includes('login') &&
      (lower.includes('plan details') || lower.includes('payment history'))) {
    console.log('Session is already active — no re-authentication needed.');
    await sleep(1500);
    await browser.close().catch(() => {});
    process.exit(0);
  }

  console.log('Session expired. Sign in to Netflix in the Chrome window.');
  console.log('The script will exit automatically once login is detected.\n');

  const startTime = Date.now();
  let loggedIn = false;

  while ((Date.now() - startTime) < timeoutSec * 1000) {
    await sleep(3000);
    try {
      const u = (page.url() || '').toLowerCase();
      const t = await page.evaluate(() => document.body.innerText.substring(0, 800)).catch(() => '');
      const l = t.toLowerCase();

      if (
        (!u.includes('login') && !u.includes('signup') &&
         (u.includes('account') || u.includes('billing'))) ||
        l.includes('payment history') ||
        l.includes('plan details')
      ) {
        if (t.length > 200) {
          loggedIn = true;
          break;
        }
      }
    } catch { }
  }

  if (loggedIn) {
    console.log('Re-authentication successful. Session saved.');
  } else {
    console.log(`Timed out after ${timeoutSec}s.`);
  }

  await sleep(2000);
  await browser.close().catch(() => {});
  process.exit(loggedIn ? 0 : 1);
}

main().catch(e => { console.error(e.message); process.exit(1); });
