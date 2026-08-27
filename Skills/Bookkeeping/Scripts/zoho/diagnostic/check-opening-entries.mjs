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
  const txns = (await (await fetch(`https://www.zohoapis.com/books/v3/banktransactions?account_id=${acctId}&organization_id=925048093&per_page=200&sort_column=date&sort_order=A`, { headers: { Authorization: `Zoho-oauthtoken ${token}` } })).json()).banktransactions || [];
  
  console.log("Opening balance entries:");
  for (const t of txns) {
    if (t.transaction_type === "opening_balance" || t.payee === "Opening Balance") {
      console.log(`  ${t.date} | $${t.amount} | ${t.debit_or_credit} | id=${t.transaction_id} | running_balance=$${t.running_balance}`);
    }
  }
  
  // Also show first 5 transactions
  console.log("\nFirst 5 transactions:");
  for (const t of txns.slice(0, 5)) {
    console.log(`  ${t.date} | $${t.amount.toString().padStart(8)} | ${t.debit_or_credit.padEnd(6)} | ${t.transaction_type.padEnd(16)} | running=$${t.running_balance}`);
  }
}
main().catch(e => console.error(e.message));
