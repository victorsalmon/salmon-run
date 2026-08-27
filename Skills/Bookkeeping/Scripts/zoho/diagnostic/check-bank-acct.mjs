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

  // First, get the current bank account details
  const acctId = "93310000000100019";
  const getUrl = `https://www.zohoapis.com/books/v3/bankaccounts/${acctId}?organization_id=925048093`;
  const getResp = await fetch(getUrl, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const acctData = await getResp.json();
  
  console.log("Current bank account:");
  console.log(`  account_name: ${acctData.bankaccount?.account_name}`);
  console.log(`  opening_balance: ${acctData.bankaccount?.opening_balance}`);
  console.log(`  currency_id: ${acctData.bankaccount?.currency_id}`);
  console.log(`  is_active: ${acctData.bankaccount?.is_active}`);
  
  // Print all relevant fields
  const ba = acctData.bankaccount || {};
  const keys = Object.keys(ba).sort();
  for (const k of keys) {
    const v = ba[k];
    if (typeof v !== "object") {
      console.log(`  ${k}: ${v}`);
    }
  }
}
main().catch(e => console.error(e.message));
