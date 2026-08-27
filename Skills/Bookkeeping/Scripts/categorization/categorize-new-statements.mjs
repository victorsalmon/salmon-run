import { chromium } from 'playwright';

const sleep = ms => new Promise(r => setTimeout(r, ms));
const ORG_ID = process.env.ORG_ID || '925048093';

function getCategory(payee) {
  const text = (payee || '').toUpperCase();
  if (!payee || payee.trim() === '') return 'Exclude';
  if (/PAYMENT.*THANK/.test(text) || /AUTOMATIC.*PAYMENT/.test(text)) return 'Exclude';
  if (/ONLINE.*BANKING/.test(text) || /E.?TRANSFER/.test(text)) return 'Exclude';
  if (/PAD.*CCRA/.test(text) || /ATM.*DEPOSIT/.test(text)) return 'Exclude';
  if (/MONTHLY.*FEE|PAY-FILE|MONTHLYFEE/.test(text)) return 'Bank Fees and Charges';
  if (/RBC.*CREDIT/.test(text)) return 'Exclude';
  if (/UPSCALE/.test(text)) return 'Consulting Revenue';
  if (/WAVE SV9T/.test(text)) return 'Consulting Revenue';
  if (/WAVE PRO/.test(text)) return 'Software & IT Expenses';
  if (/WAVE/.test(text)) return 'Consulting Revenue';
  if (/PETRO|SHELL|CHEVRON|ESSO|MOBIL|KAL.*TIRE|LORDCO|IMPARK/.test(text)) return 'Automobile Expense';
  if (/ZOHO|INTERSERVER|ANOMALY|OPENROUTER|STRIPE.*Z|PIXELLA|ROOMIES|CREATIVE.*FABRICA|FREEDOM|FONGO|NAMECHEAP|GOOGLE.*FONGO/.test(text)) return 'Software & IT Expenses';
  if (/BC.*REGISTR|LEGALSHIELD/.test(text)) return 'Professional Fees';
  if (/HOME.*DEPOT|TEMU|OZERTY/.test(text)) return 'Repairs and Maintenance';
  if (/PURCHASE.*INTEREST/.test(text)) return 'Credit Card Charges';
  if (/AMAZON|AMZN/.test(text)) return 'Other Expenses';
  if (/SGT\*PIXELLA/.test(text)) return 'Software & IT Expenses';
  return 'Other Expenses';
}

async function main() {
  const EMAIL = process.env.ZOHO_EMAIL;
  const PASS = process.env.ZOHO_PASS;
  if (!EMAIL || !PASS) { console.error('Missing ZOHO_EMAIL, ZOHO_PASS'); process.exit(1); }

  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-setuid-sandbox'] });
  const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
  let page = await context.newPage();

  // Login once
  console.log('Logging into Zoho...');
  await page.goto('https://accounts.zoho.com/signin?servicename=ZohoBooks', { waitUntil: 'networkidle0', timeout: 60000 });
  await sleep(2000);
  await page.fill('input#login_id', EMAIL);
  await page.keyboard.press('Enter');
  await sleep(5000);
  await page.fill('input#password', PASS);
  await page.keyboard.press('Enter');
  await sleep(10000);
  if ((await page.url()).includes('signin')) { console.error('Login failed'); await browser.close(); process.exit(1); }
  console.log('Logged in');

  const accounts = [
    { id: '93310000000100019', name: 'Intersite', type: 'bank' },
    { id: '93310000000100013', name: 'Intersite RBC Business Cash Back Mastercard', type: 'credit_card' },
  ];

  let totalCategorized = 0;

  for (const acct of accounts) {
    console.log(`\n=== ${acct.name} ===`);

    // Full page load to the Quick Categorize URL (reloads the whole page — avoids SPA frame detach)
    const hash = `#/banking/quickcategorize?account_id=${acct.id}&account_name=${encodeURIComponent(acct.name)}&account_type=${acct.type}&filter_by=TransactionDate.Custom&from_date=2026-04-01&group_by=payee&response_option=1&to_date=2026-06-05`;
    await page.goto(`https://books.zoho.com/app/${ORG_ID}${hash}`, { waitUntil: 'networkidle0', timeout: 120000 }).catch(() => {});
    await sleep(8000);

    const bodyText = await page.evaluate(() => document.body.innerText);
    const match = bodyText.match(/Total Uncategorized Transactions:\s*(\d+)/);
    const totalUncategorized = match ? parseInt(match[1]) : -1;
    console.log('Uncategorized:', totalUncategorized);
    if (totalUncategorized <= 0) { console.log('No uncategorized — skip'); continue; }

    for (let pageNum = 1; pageNum <= 20; pageNum++) {
      await sleep(2000);
      const groups = await page.evaluate(() => {
        const headers = document.querySelectorAll('.font-medium.text-medium.text-primary-black');
        return Array.from(headers).map(h => h.textContent.trim());
      });
      console.log(`  Page ${pageNum}: ${groups.length} payee groups`);
      if (groups.length === 0) break;

      for (let i = 0; i < groups.length; i++) {
        const payee = groups[i];
        const category = getCategory(payee);
        console.log(`    "${payee.substring(0, 35)}" -> ${category}`);

        const result = await page.evaluate((idx) => {
          const tables = document.querySelectorAll('table.cashcoding-table');
          if (idx >= tables.length) return 'no-table';
          const row = tables[idx].querySelector('tbody tr');
          if (!row) return 'no-row';
          const box = row.querySelector('.ac-box');
          if (!box) return 'no-acbox';
          const sel = box.querySelector('.ac-selected-label');
          if (sel && !sel.textContent.includes('Select')) return 'already: ' + sel.textContent.trim();
          const toggle = box.querySelector('.ac-toggle-container');
          if (toggle) toggle.click();
          return 'open';
        }, i);

        if (result === 'open') {
          await sleep(1000);
          await page.keyboard.type(category.substring(0, 10), { delay: 50 });
          await sleep(2000);

          const selected = await page.evaluate((catName) => {
            const items = document.querySelectorAll('.ac-list-item, .ac-option, .ui-select-option, li[class*="ac-"], [role="listbox"] [role="option"]');
            for (const item of items) {
              if (item.offsetParent !== null && item.textContent.trim().toUpperCase().includes(catName.toUpperCase())) {
                item.click();
                return item.textContent.trim();
              }
            }
            return null;
          }, category);

          if (selected) {
            console.log(`      ✓ ${selected}`);
            totalCategorized++;
          } else {
            console.log(`      ✗ no match for "${category}"`);
          }
          await sleep(500);
        } else {
          console.log(`      ${result}`);
        }
      }

      const hasNext = await page.evaluate(() => {
        const btn = document.querySelector('button[aria-label="Next Page"]');
        if (btn && btn.offsetParent !== null) { btn.click(); return true; }
        return false;
      });
      if (!hasNext) break;
      await sleep(5000);
    }
  }

  await browser.close();
  console.log(`\n=== ALL DONE: ${totalCategorized} groups categorized ===`);
}

main().catch(e => { console.error('Error:', e.message); process.exit(1); });
