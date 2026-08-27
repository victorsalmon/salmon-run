import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;

  const mcId = "93310000000100013";
  const txns = (await (await fetch(`https://www.zohoapis.com/books/v3/banktransactions?account_id=${mcId}&organization_id=925048093&per_page=200&sort_column=date&sort_order=A`, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json()).banktransactions || [];

  for (const t of txns) {
    if (t.date === "2025-04-01" && Math.abs(parseFloat(t.amount) - 21.78) < 0.01 && t.transaction_type === "opening_balance") {
      console.log(`Found: ${t.date} | $${t.amount} | ${t.transaction_type} | id=${t.transaction_id}`);
      // Delete it
      const delResp = await fetch(`https://www.zohoapis.com/books/v3/banktransactions/${t.transaction_id}?organization_id=925048093`, {
        method: "DELETE",
        headers: { Authorization: `Zoho-oauthtoken ${token}` }
      });
      const result = await delResp.json();
      console.log(`Delete result: code=${result.code} message=${result.message}`);
    }
  }
}
main().catch(e => console.error(e.message));
