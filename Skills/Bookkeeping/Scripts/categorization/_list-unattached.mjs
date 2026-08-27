import { fetchWithAudit } from './lib/audit-logger.mjs';
import { ZohoAuth } from './zoho-auth.js';
const ORG_ID = '925048093';
const MC_ACCT = '93310000000100013';

async function main() {
  const secrets = JSON.parse(process.env.ZOHO_SECRETS);
  const auth = new ZohoAuth({
    clientId: secrets.ZOHO_BOOKS_ID,
    clientSecret: secrets.ZOHO_BOOKS_SECRET,
    refreshToken: secrets.ZOHO_BOOKS_REFRESH
  });
  let page = 1;
  let all = [];
  while (true) {
    const url = `https://www.zohoapis.com/books/v3/expenses?organization_id=${ORG_ID}&paid_through_account_id=${MC_ACCT}&page=${page}&per_page=200`;
    const resp = await fetchWithAudit(url, { headers: { Authorization: `Zoho-oauthtoken ${await auth.getToken()}` } }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
    const data = resp.data;
    all = all.concat(data.expenses || []);
    if (!data.page_context || !data.page_context.has_more_page) break;
    page++;
  }
  const noAttach = all.filter(e => !e.has_attachment);
  for (const e of noAttach) {
    console.log(`${e.date} $${e.total} "${(e.description || e.vendor_name || '').substring(0, 80)}" [expense_id=${e.expense_id}]`);
  }
}
main().catch(e => console.error(e.message));
