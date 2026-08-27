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

  // Get account details
  const acctId = "93310000000100019";
  const getUrl = `https://www.zohoapis.com/books/v3/bankaccounts/${acctId}?organization_id=925048093`;
  const getResp = await fetch(getUrl, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const acctData = await getResp.json();
  
  console.log("Account details:");
  console.log(`  book_balance: ${acctData.bankaccount?.balance}`);
  console.log(`  bank_balance: ${acctData.bankaccount?.bank_balance}`);
  
  // Check if there's an opening_balance field in the raw response
  const raw = JSON.stringify(acctData.bankaccount, null, 2);
  if (raw.includes("opening")) {
    const lines = raw.split("\n").filter(l => l.includes("opening"));
    console.log("\nOpening balance fields in response:");
    lines.forEach(l => console.log(`  ${l.trim()}`));
  } else {
    console.log("\nNo opening_balance field in response");
  }

  // Now try PUT to update bank_balance
  console.log("\n--- Attempting to set bank_balance to match book_balance ---");
  const putBody = JSON.stringify({
    bank_balance: 1847
  });
  
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
  console.log(`PUT result: ${JSON.stringify(putResult, null, 2)}`);
}
main().catch(e => console.error(e.message));
