// aliexpress-login.js
//
// AliExpress login — persistent Chrome profile setup (first-time).
// Opens headed Chrome with a persistent profile, navigates to AliExpress,
// and waits for the user to sign in manually. Saves the session to
// ./Profile/ for subsequent use by aliexpress-persistent-downloader.js.
//
// Usage:
//   node aliexpress-login.js
//
// What to expect:
//   1. Chrome window opens to aliexpress.com
//   2. Sign in with email/password (or Google/Facebook OAuth) in the visible window
//   3. If MFA triggers, complete that in the browser too
//   4. Once the Orders page loads, the script detects success and exits,
//      saving the session to ./Profile/
//   5. Subsequent runs of the downloader skip login entirely
//
// IMPORTANT — AliExpress bot detection:
//   Do NOT use a headless browser. Real Chrome headed with a persistent
//   profile appears as a normal browser session. The profile stores
//   cookies, localStorage, and IndexedDB needed to avoid re-login.
//
//   If AliExpress shows CAPTCHA or device-verification flows, complete them
//   in the visible browser — do NOT close Chrome and retry.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { logNavigate, logError, initSession, closeSession } = require('../../lib/playwright-audit.js');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const DATA_DIR = process.env.DATA_DIR || path.resolve(__dirname, './Profile');
const LOGIN_TIMEOUT_SEC = parseInt(process.env.LOGIN_TIMEOUT || '600', 10);

// Try multiple possible order page URLs
const ORDER_URLS = [
  'https://www.aliexpress.com/p/order/index.html',
  'https://trade.aliexpress.com/orderList.htm',
  'https://www.aliexpress.com/',
];

function printSteps() {
  console.log('');
  console.log('=== ALIEXPRESS LOGIN — PERSISTENT PROFILE ===');
  console.log('');
  console.log('  A Chrome window will open. Sign in to AliExpress in that window.');
  console.log('  This script will wait and detect the login automatically.');
  console.log(`  Timeout: ${LOGIN_TIMEOUT_SEC}s`);
  console.log('');
  console.log('  Tips:');
  console.log('    - Sign in with email + password or Google/Facebook');
  console.log('    - If CAPTCHA appears, complete it in the browser');
  console.log('    - If MFA/2FA triggers (verification code via email), check your inbox');
  console.log('    - Do NOT close Chrome until the script says "Login complete"');
  console.log('');
}

async function detectLoggedIn(page) {
  const url = (page.url() || '').toLowerCase();
  const txt = await page.evaluate(() => document.body.innerText.substring(0, 1500)).catch(() => '');
  const lower = txt.toLowerCase();

  // Not logged in if on login/passport page
  if (url.includes('login') || url.includes('passport') || url.includes('signin')) {
    return false;
  }

  // Logged in if we have substantial page content and see order-related terms
  if (txt.length > 500 && (
    lower.includes('my orders') ||
    lower.includes('order list') ||
    lower.includes('order') && lower.includes('total') ||
    url.includes('order')
  )) {
    return true;
  }

  // On homepage with account menu visible
  if (txt.length > 500 && lower.includes('sign out')) {
    return true;
  }

  return false;
}

async function main() {
  initSession('web', 'aliexpress-login');
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

  // Navigate to first order URL — will redirect to login if unauthenticated
  console.log('Opening AliExpress...');
  for (const url of ORDER_URLS) {
    try {
      await logNavigate(page, url, { domain: 'web', subdomain: 'aliexpress', session: 'aliexpress-login' });
      await sleep(5000);
      if (await detectLoggedIn(page)) {
        console.log('\nAlready logged in. Session is active.\n');
        await sleep(1000);
        await browser.close().catch(() => {});
        closeSession('aliexpress-login');
        process.exit(0);
      }
      // If we got past login, we're good
      const currentUrl = (page.url() || '').toLowerCase();
      if (!currentUrl.includes('login') && !currentUrl.includes('passport')) {
        break;
      }
    } catch {
      await page.goto(url, { timeout: 60000 }).catch(() => {});
      await sleep(5000);
    }
  }

  // Check if already logged in
  if (await detectLoggedIn(page)) {
    console.log('\nAlready logged in. Session is active.\n');
    await sleep(1000);
    await browser.close().catch(() => {});
    closeSession('aliexpress-login');
    process.exit(0);
  }

  // Not logged in — wait for manual sign-in
  console.log('\nPlease sign in to AliExpress in the Chrome window.');
  console.log('The script will continue once the Orders page loads.\n');

  const startTime = Date.now();
  let loggedIn = false;

  while ((Date.now() - startTime) < LOGIN_TIMEOUT_SEC * 1000) {
    await sleep(5000);
    try {
      if (await detectLoggedIn(page)) {
        loggedIn = true;
        console.log('\nLogin detected! Session saved to persistent profile.\n');
        break;
      }
    } catch { /* page mid-navigation */ }
  }

  if (!loggedIn) {
    console.log(`\nTimed out after ${LOGIN_TIMEOUT_SEC}s.`);
    console.log('Run again when you can complete the sign-in process.');
  }

  await sleep(2000);
  await browser.close().catch(() => {});
  closeSession('aliexpress-login');
  process.exit(loggedIn ? 0 : 1);
}

main().catch(e => { logError(null, 'aliexpress-login', e, 'main-flow').catch(() => {}); console.error(e.message); process.exit(1); });
