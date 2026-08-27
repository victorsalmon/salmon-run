import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");

async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
    refresh_token: creds.refreshToken,
    grant_type: "refresh_token"
  });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const data = await resp.json();
  const token = data.access_token;

  // Fetch all RBC transactions with opening_balance type
  const url = "https://www.zohoapis.com/books/v3/banktransactions?account_id=93310000000100019&organization_id=925048093&per_page=200&sort_column=date&sort_order=A";
  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  const txns = result.banktransactions || [];

  // Show the $8 opening_balance entry in detail
  for (const t of txns) {
    const amt = parseFloat(t.amount);
    if (t.transaction_type === "opening_balance" || (Math.abs(amt - 8) < 0.5 && t.date.startsWith("2025-04"))) {
      console.log(JSON.stringify(t, null, 2));
      console.log("---");
    }
  }
}
main().catch(e => console.error(e.message));
