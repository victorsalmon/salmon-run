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

  const orgId = "925048093";
  const acctId = "93310000000100019";
  const url = `https://www.zohoapis.com/books/v3/banktransactions?account_id=${acctId}&organization_id=${orgId}&per_page=200&sort_column=date&sort_order=D`;

  const getResp = await fetch(url, {
    headers: { Authorization: `Zoho-oauthtoken ${token}` }
  });
  const result = await getResp.json();
  
  // Count by transaction_type
  const types = {};
  for (const t of (result.banktransactions || [])) {
    types[t.transaction_type] = (types[t.transaction_type] || 0) + 1;
  }
  console.log("Transaction types:", JSON.stringify(types));
  console.log("Total:", (result.banktransactions || []).length);
  
  // Show last 5 transactions
  const txns = result.banktransactions || [];
  for (let i = 0; i < 5 && i < txns.length; i++) {
    const t = txns[i];
    console.log(`  ${t.date} | ${t.transaction_type.padEnd(15)} | ${t.payee.padEnd(50)} | $${t.amount} | id=${t.banktransaction_id}`);
  }
  
  // Check if any Credit Card Payments expense entries still exist
  const ccPayments = txns.filter(t => t.payee === "Credit Card Payments" || t.payee === "Credit Card Charges");
  console.log(`\nCredit Card Payments/Charges entries remaining: ${ccPayments.length}`);
  ccPayments.forEach(t => console.log(`  ${t.date} | ${t.transaction_type} | $${t.amount} | id=${t.banktransaction_id}`));
}
main().catch(e => console.error(e.message));
