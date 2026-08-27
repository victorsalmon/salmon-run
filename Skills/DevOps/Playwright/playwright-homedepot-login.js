const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { logNavigate, logError, initSession, closeSession } = require('../../lib/playwright-audit.js');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const COOKIE_FILE = path.resolve(__dirname, '.homedepot-session.json');
const CDP_PORT = 9222;
const TIMEOUT_SEC = parseInt(process.env.REAUTH_TIMEOUT || '600', 10);

function printSteps() {
  console.log('');
  console.log('=== CONNECTING TO YOUR REAL CHROME ===');
  console.log('1. Close ALL Chrome windows.');
  console.log(`2. Run in PowerShell:  & "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --remote-debugging-port=${CDP_PORT}`);
  console.log('   (Select your profile when Chrome opens.)');
  console.log('3. Press Enter here once Chrome is open.');
  console.log('');
}

async function connectToChrome() {
  printSteps();
  await new Promise(resolve => process.stdin.once('data', resolve));
  await sleep(2000);
  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`);
  const pages = await browser.pages();
  const page = pages.length > 0 ? pages[0] : await browser.newPage();
  const context = browser.contexts()[0];
  return { browser, context, page };
}

async function waitForLogin(page) {
  console.log('\nNavigate to https://www.homedepot.ca/ and sign in manually.');
  console.log('The script will detect the purchase history page automatically.\n');

  const startTime = Date.now();
  while ((Date.now() - startTime) < TIMEOUT_SEC * 1000) {
    await sleep(5000);
    try {
      const url = page.url().toLowerCase();
      if (url.includes('purchase-history')) {
        const txt = await page.evaluate(() => document.body.innerText.substring(0, 500)).catch(() => '');
        if (txt.length > 100 && !txt.toLowerCase().includes('sign in')) {
          console.log(' Login detected on purchase history page.');
          return true;
        }
      }
    } catch { /* page mid-nav */ }
  }
  console.log(`Timed out after ${TIMEOUT_SEC}s.`);
  return false;
}

async function saveCookies(context) {
  const cookies = await context.cookies();
  if (cookies.length > 0) {
    fs.writeFileSync(COOKIE_FILE, JSON.stringify({ cookies, savedAt: Date.now() }, null, 2));
    console.log(`Saved ${cookies.length} cookies to ${path.basename(COOKIE_FILE)}`);
    return true;
  }
  console.log('No cookies to save.');
  return false;
}

async function main() {
  initSession('web', 'homedepot-login');
  console.log('Home Depot Login — CDP (connect to real Chrome)\n');

  const { browser, context, page } = await connectToChrome();

  await page.goto('https://www.homedepot.ca/', { timeout: 30000 }).catch(() => {});
  await sleep(4000);

  const loggedIn = await waitForLogin(page);
  if (loggedIn) await saveCookies(context);

  console.log('\nYou can close the Chrome window.');
  closeSession('homedepot-login');
  process.exit(loggedIn ? 0 : 1);
}

main().catch(e => { logError(null, 'homedepot-login', e, 'main-flow').catch(() => {}); console.error('Fatal:', e.message); process.exit(1); });
