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

  const acctId = "93310000000100019";
  
  // Try PUT with opening_balance field
  const putBody = JSON.stringify({
    account_id: acctId,
    opening_balance: 6211.99,  // reduce from 6219.99 by 8
    currency_id: "93310000000000101"
  });
  
  console.log("Sending:", putBody);
  
  const putResp = await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${acctId}?organization_id=925048093`, {
    method: "PUT",
    headers: { 
      Authorization: `Zoho-oauthtoken ${token}`,
      "Content-Type": "application/json"
    },
    body: putBody
  });
  const putResult = await putResp.json();
  console.log(`PUT status: ${putResp.status}`);
  console.log(`Result: ${JSON.stringify(putResult, null, 2)}`);
}
main().catch(e => console.error(e.message));
