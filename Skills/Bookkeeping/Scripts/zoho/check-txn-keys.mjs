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

  const url = "https://www.zohoapis.com/books/v3/banktransactions?account_id=93310000000100019&organization_id=925048093&per_page=3&sort_column=date&sort_order=D";
  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  
  // Show full first transaction to see all fields
  console.log("First transaction keys:", Object.keys(result.banktransactions[0]).join(", "));
  console.log(JSON.stringify(result.banktransactions[0], null, 2));
  
  // Count by payee
  const payees = {};
  for (const t of (result.banktransactions || [])) {
    const key = t.payee || "(blank)";
    payees[key] = (payees[key] || 0) + 1;
  }
  console.log("Payee breakdown:", JSON.stringify(payees, null, 2));
}
main().catch(e => console.error(e.message));
