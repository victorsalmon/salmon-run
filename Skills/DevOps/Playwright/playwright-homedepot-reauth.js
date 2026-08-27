const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const CDP_PORT = 9222;
const TIMEOUT_SEC = parseInt(process.env.REAUTH_TIMEOUT || process.argv.find(a => a.startsWith('--timeout='))?.split('=')[1] || '600', 10);

async function main() {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    console.log('Home Depot Re-Authenticator (CDP)');
    console.log('Connects to your real Chrome via CDP, waits for you to sign in.');
    console.log('');
    console.log('Usage: node homedepot-reauth.js [--timeout=600]');
    console.log('');
    console.log('Prerequisites:');
    console.log('  1. Close all Chrome windows');
    console.log('  2. Run:  & "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --remote-debugging-port=9222');
    console.log('  3. Run this script');
    process.exit(0);
  }

  console.log('Home Depot Re-Authenticator');
  console.log(`Timeout: ${TIMEOUT_SEC}s`);
  console.log('');
  console.log('Close all Chrome windows, then run:');
  console.log('  & "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --remote-debugging-port=9222');
  console.log('');
  console.log('Press Enter when Chrome is open...');
  await new Promise(resolve => process.stdin.once('data', resolve));
  await sleep(2000);

  const browser = await chromium.connectOverCDP(`http://127.0.0.1:${CDP_PORT}`);
  const pages = await browser.pages();
  const page = pages.length > 0 ? pages[0] : await browser.newPage();

  await page.goto('https://www.homedepot.ca/', { timeout: 30000 }).catch(() => {});
  await sleep(4000);

  console.log('\nSign in to Home Depot in the Chrome window.');
  console.log('The script will close automatically once login is detected.\n');

  const startTime = Date.now();
  let loggedIn = false;

  while ((Date.now() - startTime) < TIMEOUT_SEC * 1000) {
    await sleep(5000);
    try {
      const url = page.url().toLowerCase();
      if (url.includes('purchase-history')) {
        const txt = await page.evaluate(() => document.body.innerText.substring(0, 500)).catch(() => '');
        if (txt.length > 100 && !txt.toLowerCase().includes('sign in')) {
          loggedIn = true;
          break;
        }
      }
    } catch { }
  }

  if (loggedIn) {
    console.log('Re-authentication successful.');
  } else {
    console.log(`Timed out after ${TIMEOUT_SEC}s.`);
  }

  await sleep(2000);
  process.exit(loggedIn ? 0 : 1);
}

main().catch(e => { console.error(e.message); process.exit(1); });
