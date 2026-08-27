import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;

  const acctId = "93310000000100019";
  const ba = await (await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${acctId}?organization_id=925048093`, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  })).json();
  
  console.log("RBC account:");
  console.log(`  opening_balance: ${ba.bankaccount?.opening_balance}`);
  console.log(`  book balance: ${ba.bankaccount?.balance}`);
  console.log(`  bank_balance: ${ba.bankaccount?.bank_balance}`);
  
  // Also dump all fields that might relate to opening
  const baObj = ba.bankaccount || {};
  for (const [k, v] of Object.entries(baObj)) {
    if (k.toLowerCase().includes("open") || k.toLowerCase().includes("balance")) {
      console.log(`  ${k}: ${v}`);
    }
  }
}
main().catch(e => console.error(e.message));
