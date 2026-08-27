import { createRequire } from "module";
const require = createRequire(import.meta.url);
const { getSecret } = require("../shared/lib/get-secret.js");
async function main() {
  const parsed = getSecret();
  const creds = { clientId: parsed.ZOHO_BOOKS_ID, clientSecret: parsed.ZOHO_BOOKS_SECRET, refreshToken: parsed.ZOHO_BOOKS_REFRESH };
  const body = new URLSearchParams({ client_id: creds.clientId, client_secret: creds.clientSecret, refresh_token: creds.refreshToken, grant_type: "refresh_token" });
  const resp = await fetch("https://accounts.zoho.com/oauth/v2/token", { method: "POST", body });
  const token = (await resp.json()).access_token;

  // Get MC account details
  const mcId = "93310000000100013";
  const ba = await (await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${mcId}?organization_id=925048093`, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json();
  
  console.log("MC account details:");
  console.log(`  opening_balance: ${ba.bankaccount?.opening_balance}`);
  console.log(`  balance: ${ba.bankaccount?.balance}`);
  console.log(`  bank_balance: ${ba.bankaccount?.bank_balance}`);
  
  // Try PUT to add $21.78 to opening balance (which would offset the phantom $21.78 debit)
  // The opening_balance field might be the raw OB, not adjusted by the opening_balance transaction
  console.log("\nAttempting to adjust opening balance...");
  const putBody = JSON.stringify({
    account_id: mcId,
    opening_balance: 843.13,  // $821.35 (journal) + $21.78 (adjustment)
    currency_id: "93310000000000101"
  });
  
  const putResp = await fetch(`https://www.zohoapis.com/books/v3/bankaccounts/${mcId}?organization_id=925048093`, {
    method: "PUT",
    headers: { Authorization: `Zoho-oauthtoken ${token}`, "Content-Type": "application/json" },
    body: putBody
  });
  const result = await putResp.json();
  console.log(`PUT status: ${putResp.status}`);
  console.log(`Result: ${JSON.stringify(result, null, 2)}`);
}
main().catch(e => console.error(e.message));
