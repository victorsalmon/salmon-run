import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;
  const url = "https://www.zohoapis.com/books/v3/reports/trialbalance?organization_id=925048093&as_of_date=2026-07-06";
  const tb = await (await fetch(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
  function findAcct(entries, pat) {
    let r = [];
    for (const e of entries || []) {
      if (e.name && e.name.match(pat)) { const d = e.net_debit_total ? parseFloat(e.net_debit_total) : 0; const c = e.net_credit_total ? parseFloat(e.net_credit_total) : 0; r.push({ name: e.name, debit: d, credit: c }); }
      if (e.account_transactions) r = r.concat(findAcct(e.account_transactions, pat));
    }
    return r;
  }
  const keys = ["Opening Balance", "Retained Earnings", "RBC", "MC", "Mastercard"];
  for (const k of keys) {
    const results = findAcct(tb.trialbalance, k);
    for (const r of results) {
      const d = r.debit ? `${r.debit.toFixed(2)} DR`.padStart(14) : "".padStart(14);
      const c = r.credit ? `${r.credit.toFixed(2)} CR`.padStart(14) : "".padStart(14);
      console.log(`  ${r.name.padEnd(52)} ${d} ${c}`);
    }
  }
}
main().catch(e => console.error(e.message));
