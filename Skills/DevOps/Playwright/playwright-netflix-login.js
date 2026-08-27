// netflix-login.js
//
// Netflix login — persistent Chrome profile setup (first-time).
// Opens headed Chrome with a persistent profile, navigates to Netflix,
// and waits for the user to sign in manually. Saves the session to
// ./Profile/ for subsequent use by netflix-receipt-downloader.js.
//
// Usage:
//   node netflix-login.js
//
// What to expect:
//   1. Chrome window opens to netflix.com/login
//   2. Sign in with email + password in the visible window
//   3. If MFA triggers (Netflix sends a verification code to your email),
//      complete that in the browser too
//   4. Once the billing history page loads, the script detects success
//      and exits, saving the session to ./Profile/
//   5. Subsequent runs of the downloader skip login entirely
//
// IMPORTANT — Netflix bot detection:
//   Do NOT use a headless browser. Real Chrome headed with a persistent
//   profile appears as a normal browser session. The profile stores
//   cookies, localStorage, and IndexedDB needed to avoid re-login.
//
//   If Netflix shows "Update your account" or device-verification flows,
//   complete them in the visible browser — do NOT close Chrome and retry.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { logNavigate, logError, initSession, closeSession } = require('../../lib/playwright-audit.js');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const DATA_DIR = process.env.DATA_DIR || path.resolve(__dirname, './Profile');
const LOGIN_TIMEOUT_SEC = parseInt(process.env.LOGIN_TIMEOUT || '600', 10);
const NEXUS_URL = 'https://www.netflix.com/account/membership';

function printSteps() {
  console.log('');
  console.log('=== NETFLIX LOGIN — PERSISTENT PROFILE ===');
  console.log('');
  console.log('  A Chrome window will open. Sign in to Netflix in that window.');
  console.log('  This script will wait and detect the login automatically.');
  console.log(`  Timeout: ${LOGIN_TIMEOUT_SEC}s`);
  console.log('');
  console.log('  Tips:');
  console.log('    - If MFA triggers (verification email), check your inbox');
  console.log('    - If "Update your account" page appears, complete it');
  console.log('    - Do NOT close Chrome until the script says "Login complete"');
  console.log('    - Netflix may ask about device trust — answer in the browser');
  console.log('');
}

async function main() {
  initSession('web', 'netflix-login');
  printSteps();

  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
  console.log(`Profile: ${DATA_DIR}\n`);

  const browser = await chromium.launchPersistentContext(DATA_DIR, {
    headless: false,
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-first-run',
      '--no-default-browser-check',
    ]
  });

  const pages = browser.pages();
  const page = pages.length > 0 ? pages[0] : await browser.newPage();

  // Navigate to Netflix Account page — this will redirect to /login if unauthenticated
  console.log('Opening Netflix account page...');
  try {
    await logNavigate(page, NEXUS_URL, { domain: 'web', subdomain: 'netflix', session: 'netflix-login' });
  } catch {
    // First goto may fail due to redirects; retry without waitUntil
    await page.goto(NEXUS_URL, { timeout: 60000 }).catch(() => {});
  }
  await sleep(5000);

  // Detect login state: check URL and page content
  const currentUrl = (page.url() || '').toLowerCase();
  const bodyText = await page.evaluate(() => document.body.innerText.substring(0, 1000)).catch(() => '');
  const bodyLower = bodyText.toLowerCase();

  const isLoggedIn = (
    (currentUrl.includes('account') || currentUrl.includes('membership')) &&
    !currentUrl.includes('login') &&
    (bodyLower.includes('plan details') || bodyLower.includes('membership') || bodyLower.includes('payment'))
  );

  if (isLoggedIn) {
    console.log('\nAlready logged in. Session is active.\n');
    await sleep(1000);
    await browser.close().catch(() => {});
    closeSession('netflix-login');
    process.exit(0);
  }

  // Not logged in — wait for manual sign-in
  console.log('\nPlease sign in to Netflix in the Chrome window.');
  console.log('The script will continue once the Account page loads.\n');

  const startTime = Date.now();
  let loggedIn = false;

  while ((Date.now() - startTime) < LOGIN_TIMEOUT_SEC * 1000) {
    await sleep(5000);
    try {
      const url = (page.url() || '').toLowerCase();
      const txt = await page.evaluate(() => document.body.innerText.substring(0, 1000)).catch(() => '');

      // Detect login by any of these signals:
      // 1. URL contains "youraccount" (no "login" in URL)
      // 2. Page mentions billing history, plan details, membership
      // 3. URL is the billing history page or contains billing
      if (
        (!url.includes('login') && !url.includes('signup') && (url.includes('account') || url.includes('billing'))) ||
        txt.toLowerCase().includes('payment history') ||
        txt.toLowerCase().includes('plan details') ||
        (txt.toLowerCase().includes('membership') && txt.toLowerCase().includes('cancel'))
      ) {
        if (txt.length > 200) {
          loggedIn = true;
          console.log('\nLogin detected! Session saved to persistent profile.\n');
          break;
        }
      }
    } catch { /* page mid-navigation */ }
  }

  if (!loggedIn) {
    console.log(`\nTimed out after ${LOGIN_TIMEOUT_SEC}s.`);
    console.log('Run again when you can complete the sign-in process.');
  }

  await sleep(2000);
  await browser.close().catch(() => {});
  closeSession('netflix-login');
  process.exit(loggedIn ? 0 : 1);
}

main().catch(e => { logError(null, 'netflix-login', e, 'main-flow').catch(() => {}); console.error(e.message); process.exit(1); });
