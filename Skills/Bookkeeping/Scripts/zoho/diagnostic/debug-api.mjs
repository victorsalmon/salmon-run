import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;
  
  // Try different date formats
  const url = "https://www.zohoapis.com/books/v3/reports/trialbalance?organization_id=925048093&as_of_date=2026-06-30";
  const tb = await (await fetch(url, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
  
  console.log("Code:", tb.code);
  console.log("Message:", tb.message);
  console.log("TB has data:", Array.isArray(tb.trialbalance) ? tb.trialbalance.length : typeof tb.trialbalance);
  
  // Try a simpler API call first - list bank accounts
  const ba = await (await fetch("https://www.zohoapis.com/books/v3/bankaccounts?organization_id=925048093", { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
  console.log("Bank accounts:", ba.bankaccounts?.length);
}
main().catch(e => console.error(e.message));
