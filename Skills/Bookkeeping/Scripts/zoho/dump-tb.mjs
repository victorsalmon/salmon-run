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
  
  // Dump all account names
  function dump(entries, depth) {
    for (const e of entries || []) {
      if (e.name) console.log(`${" ".repeat(depth*2)}${e.name} | debit=${e.net_debit_total} credit=${e.net_credit_total}`);
      if (e.account_transactions) dump(e.account_transactions, depth + 1);
    }
  }
  dump(tb.trialbalance, 0);
}
main().catch(e => console.error(e.message));
