import { ZohoAuth } from './zoho-auth.js';

async function main() {
  const secrets = JSON.parse(process.env.ZOHO_SECRETS);
  const auth = new ZohoAuth({
    clientId: secrets.ZOHO_BOOKS_ID,
    clientSecret: secrets.ZOHO_BOOKS_SECRET,
    refreshToken: secrets.ZOHO_BOOKS_REFRESH
  });
  const token = await auth.getToken();
  
  const ORG_ID = '925004567';
  let page = 1;
  let allExpenses = [];
  while (true) {
    const url = `https://www.zohoapis.com/books/v3/expenses?organization_id=${ORG_ID}&page=${page}&per_page=200`;
    const resp = await fetch(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } });
    const data = await resp.json();
    if (!data.expenses) break;
    allExpenses = allExpenses.concat(data.expenses);
    if (!data.page_context?.has_more_page) break;
    page++;
  }

  const noAtt = allExpenses.filter(e => !e.has_attachment);
  
  const cats = {};
  for (const e of noAtt) {
    const d = (e.description || e.vendor_name || '').toLowerCase();
    let cat = 'Other/Unknown';
    if (d.includes('amazon') || d.includes('amzn')) cat = 'Amazon';
    else if (d.includes('home depot')) cat = 'Home Depot';
    else if (d.includes('meta') || d.includes('facebook')) cat = 'Meta/Facebook';
    else if (d.includes('lightspeed') || d.includes('internet')) cat = 'Lightspeed/Internet';
    else if (d.includes('intersite')) cat = 'Intersite Consulting';
    else if (d.includes('petro') || d.includes('shell') || d.includes('chevron') || d.includes('super save') || d.includes('gas') || d.includes('co-op')) cat = 'Fuel/Gas';
    else if (d.includes('kal') || d.includes('tire')) cat = 'Kal Tire';
    else if (d.includes('bc hydro') || d.includes('bch') || e.account_name === 'Utilities') cat = 'BC Hydro/Utilities';
    else if (d.includes('ikea')) cat = 'IKEA';
    else if (d.includes('coina')) cat = 'Coinamatic';
    else if (d.includes('bank') || d.includes('fee')) cat = 'Bank Fees';
    else if (e.account_name === 'Credit Card Payments') cat = 'Credit Card Payment';
    else if (e.account_name === 'Rent Expense') cat = 'Rent';
    else if (e.account_name === 'Advertising And Marketing' && !d.includes('meta')) cat = 'Advertising';
    
    if (!cats[cat]) cats[cat] = {items:[], total:0};
    cats[cat].items.push(e);
    cats[cat].total += parseFloat(e.total || 0);
  }
  
  console.log('=== ROOM RENTALS — EXPENSES WITHOUT RECEIPT IN ZOHO ===');
  console.log(`Total unattached: ${noAtt.length}`);
  console.log('');
  
  const sorted = Object.entries(cats).sort((a,b) => b[1].items.length - a[1].items.length);
  for (const [cat, {items, total}] of sorted) {
    console.log(`${cat}: ${items.length} items, $${total.toFixed(2)}`);
    for (const e of items) {
      const desc = (e.description || '').substring(0, 70);
      const acct = e.account_name || '';
      const amt = String(parseFloat(e.total).toFixed(2)).padStart(8);
      console.log(`  ${e.date} $${amt} | ${acct.padEnd(28)} | ${desc}`);
    }
  }
  
  // Also show which on-disk receipts exist vs missing
  console.log('');
  console.log('=== ON-DISK RECEIPTS IN 2026 RECEIPTS/ ===');
  console.log('(these MD sidecar files exist but may not be uploaded to Zoho)');
}

main().catch(e => console.error('Error:', e.message));
