const pw = require('playwright');
const sleep = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const browser = await pw.chromium.connectOverCDP(`ws://FRAD_mcp_browserless:21006?token=${process.env.BROWSERLESS_TOKEN}`);
  const page = await browser.newPage();
  await page.setViewportSize({ width: 1400, height: 900 });

  // Login
  console.log('Logging in...');
  await page.goto('https://accounts.zoho.com/signin?servicename=ZohoBooks', { waitUntil: 'networkidle', timeout: 60000 });
  await sleep(2000);
  await page.fill('input#login_id', process.env.ZOHO_EMAIL);
  await page.keyboard.press('Enter');
  await sleep(4000);
  await page.fill('input#password', process.env.ZOHO_PASS);
  await page.keyboard.press('Enter');
  await sleep(8000);
  console.log('Login URL:', page.url().substring(0, 120));

  // Navigate to app
  await page.goto('https://books.zoho.com/app/925048093', { waitUntil: 'domcontentloaded', timeout: 30000 });
  await sleep(5000);
  console.log('App URL:', page.url().substring(0, 120));

  // Instead of hash change, try page.goto
  const appUrl = 'https://books.zoho.com/app/925048093#/banking/quickcategorize?account_id=93310000000100013&account_name=Intersite%20RBC%20Business%20Cash%20Back%20Mastercard&account_type=credit_card&filter_by=TransactionDate.PreviousYear&from_date=2025-04-01&group_by=payee&response_option=1&to_date=2026-03-31';
  console.log('Navigating via goto with hash...');
  await page.goto(appUrl, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(e => console.log('goto error:', e.message));
  await sleep(5000);

  try {
    console.log('After nav URL:', page.url().substring(0, 150));
    const info = await page.evaluate(() => document.body.innerText.substring(0, 500));
    console.log('Body:', info);
  } catch (e) {
    console.log('Page dead after goto:', e.message);
  }

  await browser.close();
  console.log('Done');
})().catch(err => { console.error(err); process.exit(1); });
