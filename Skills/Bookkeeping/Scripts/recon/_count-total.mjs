import { fetchWithAudit } from './lib/audit-logger.mjs';
import { ZohoAuth } from 'file:///C:/Users/Victor/intersite-orchestrator/Skills/Bookkeeping/Scripts/zoho-auth.js';
const ORG_ID = '925048093';

async function fetchExpensesForAccount(auth, accountId, label) {
  let p = 1, t = [], at = 0, na = 0;
  while (true) {
    let u = `https://www.zohoapis.com/books/v3/expenses?organization_id=${ORG_ID}&page=${p}&per_page=200`;
    if (accountId) u += `&paid_through_account_id=${accountId}`;
    const r = await fetchWithAudit(u, { headers: { Authorization: 'Zoho-oauthtoken '+(await auth.getToken()) } }, { domain: 'Bookkeeper', action: 'zoho:expenses:list' });
    const d = r.data;
    t = t.concat(d.expenses || []);
    if (!d.page_context || !d.page_context.has_more_page) break;
    p++;
  }
  for (const e of t) { if (e.has_attachment) at++; else na++; }
  if (label) console.log(`ACCOUNT:${label} TOTAL:${t.length} ATTACHED:${at} UNATTACHED:${na}`);
  return { total: t.length, attached: at, unattached: na };
}

async function fetchAllAccounts(auth) {
  const u = `https://www.zohoapis.com/books/v3/chartofaccounts?organization_id=${ORG_ID}&filter_by=AccountStatus.Active&account_type=expense`;
  const r = await fetchWithAudit(u, { headers: { Authorization: 'Zoho-oauthtoken '+(await auth.getToken()) } }, { domain: 'Bookkeeper', action: 'zoho:accounts:list' });
  const d = r.data;
  return (d.chartofaccounts || []).filter(a => a.is_user_created || a.account_name.match(/chequing|mastercard|visa|bank/i));
}

async function main() {
  const args = process.argv.slice(2);
  let accountFilter = null;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--account') accountFilter = args[++i];
  }
  const s = JSON.parse(process.env.ZOHO_SECRETS);
  const a = new ZohoAuth({ clientId: s.ZOHO_BOOKS_ID, clientSecret: s.ZOHO_BOOKS_SECRET, refreshToken: s.ZOHO_BOOKS_REFRESH });
  if (accountFilter) {
    await fetchExpensesForAccount(a, accountFilter, 'filtered');
  } else {
    const accounts = await fetchAllAccounts(a);
    let grandTotal = 0, grandAttached = 0, grandUnattached = 0;
    for (const acct of accounts) {
      const result = await fetchExpensesForAccount(a, acct.account_id, acct.account_name);
      grandTotal += result.total;
      grandAttached += result.attached;
      grandUnattached += result.unattached;
    }
    console.log(`GRAND TOTAL:${grandTotal} ATTACHED:${grandAttached} UNATTACHED:${grandUnattached}`);
  }
}
main().catch(e => { console.error(e.message); process.exit(1); });
