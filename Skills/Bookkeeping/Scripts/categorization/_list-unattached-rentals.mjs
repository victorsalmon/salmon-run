import { ZohoAuth } from './zoho-auth.js';

const ORG_ID = '925004567';

async function main() {
  const secrets = JSON.parse(process.env.ZOHO_SECRETS);
  const auth = new ZohoAuth({
    clientId: secrets.ZOHO_BOOKS_ID,
    clientSecret: secrets.ZOHO_BOOKS_SECRET,
    refreshToken: secrets.ZOHO_BOOKS_REFRESH
  });
  const token = await auth.getToken();
  
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

  console.log(`Total expenses in Zoho (room-rentals): ${allExpenses.length}`);
  
  const withAttach = allExpenses.filter(e => e.has_attachment);
  const noAttach = allExpenses.filter(e => !e.has_attachment);
  
  console.log(`With attachment: ${withAttach.length}`);
  console.log(`Without attachment: ${noAttach.length}`);
  console.log('---');
  console.log('EXPENSES WITHOUT RECEIPT ATTACHMENT:');
  for (const e of noAttach) {
    console.log(`${e.date} | $${e.total} | ${e.vendor_name||''} | ${e.account_name||''} | ${(e.description||'').substring(0,80)} | id=${e.expense_id}`);
  }
  
  console.log('---');
  console.log('ALL VENDORS (with attachment counts):');
  const vendorCounts = {};
  for (const e of allExpenses) {
    const v = e.vendor_name || 'Unknown';
    if (!vendorCounts[v]) vendorCounts[v] = { total: 0, withAtt: 0, withoutAtt: 0, totalAmt: 0 };
    vendorCounts[v].total++;
    vendorCounts[v].totalAmt += parseFloat(e.total || 0);
    if (e.has_attachment) vendorCounts[v].withAtt++;
    else vendorCounts[v].withoutAtt++;
  }
  for (const [v, c] of Object.entries(vendorCounts).sort((a,b) => b[1].total - a[1].total)) {
    console.log(`${v}: ${c.total} expenses (${c.withAtt} with receipt, ${c.withoutAtt} without) - $${c.totalAmt.toFixed(2)}`);
  }
}

main().catch(e => console.error('Error:', e.message));
